# =============================================================================
# fan_out_grain -- how many workers a fork wakes, and the grain they split by
# =============================================================================
#
# Three pure functions of exact facts known at the fork (the input's row or
# byte count and the pool size), so they are resolved at dispatch time rather
# than recorded in the physical plan:
#
#   * `capped_worker_count`  -- the opt-in fan-out cap (default off)
#   * `parallel_fork_grain`  -- the wave-snapped rows per morsel of a fork
#   * `parallel_copy_tiles`  -- tiles per unit of a bulk-copy fan
#
# None of them reads the environment, a global, or a producer statistic.
# =============================================================================

# =============================================================================
# FAN-OUT CAP — worker over-subscription / idle-busy-spin lever
# (TPC-H profile)
# =============================================================================
#
# THE FINDING. On a small working set the engine still fans a parallel
# operator across the FULL worker pool (`engine_worker_count()`, ~20 on this
# 14700K box). The TPC-H profile measured, across q2/q5/q16, that
# the FIXED per-task dispatch overhead + the workers' bounded-spin-then-park
# idle loop dominate the wall when the per-worker share is tiny:
#   * q2 ~38% idle-parallel spin (an ~800K-row working set fanned across 20
#     workers that then spin on nothing — plus the nation(25)/region(5) dim
#     builds fanned across the whole pool).
#   * q5 ~27% async-dispatch share (per-operator run_with_state fan-out cost).
#   * q16 ~55% of samples = 27 workers busy-spinning in the worker park loop.
#
# THE LEVER (a POLICY heuristic, NOT a runtime/async-primitive change).
# `capped_worker_count(working_set_rows, max_workers)` caps the worker count so
# each dispatched worker owns at least `MIN_ROWS_PER_WORKER` rows. It is applied
# CENTRALLY in `execute_collect_morsel_sink` off the source's `row_count_hint()`
# — the one seam every morsel-sink dispatch (typed-join probe, walker leaf,
# resident join, hash-agg, sort, collect) flows through. `run_with_state` honors
# a reduced task count (`n_workers = min(worker_count, n)`), so the un-dispatched
# pool workers never receive a task.
#
# VERDICT: MEASURED WASH -> LANDED OPT-IN (DEFAULT-OFF). A warm-context ABBA
# threshold sweep (q2/q5/q16, {2K..131K} rows/worker vs the full pool) measured
# this cap as a wash — ~0.96-1.00x, within run-to-run noise, net-negative at some
# thresholds. ROOT CAUSE: the profile's busy-spin is the worker POOL's idle
# bounded-spin-then-park loop, which fires in the idle workers REGARDLESS of a
# dispatch's width — reducing the fan-out does not quiet it and costs parallelism
# on the genuinely-parallel work. The effective lever is the pool PARK POLICY in
# `komira_async/runtime` (the moat line), not this knob. So the primitive is
# DEFAULT-OFF (byte-and-wall-identical default); it is preserved as a
# cardinality-aware fan-out substrate a future pool-level scheduler can combine
# with a quieter park policy. The caller's own configuration engages it (there
# is no switch in this module) and `capped_worker_count`'s `min_rows_per_worker`
# argument tunes the threshold.
#
# WHEN ENABLED it is answer-preserving for the SET of rows (the return is in
# `[1, max_workers]`; sink combines + corpus VALDUMP are order-independent), and
# it never throttles a large scan (6M/25M/100M rows >> max_workers * threshold ->
# no cap). It DOES perturb parallel f64 agg sums at ~1e-10 relative (worker-count-
# dependent reduction order; row-count-identical, within DuckDB rel_tol).

# The default amortization threshold: a dispatched worker should own at least
# this many rows before it earns a slot. 131072 (== MAX_MORSEL_ROWS_DEFAULT)
# was chosen so an ~800K working set collapses to ~6 workers (matching the
# ~4-6-worker light-per-RG optimum the CB02/PER-RG worker-cap memos measured on
# this box) while a 6M-lineitem set (÷131072 ≈ 46) stays clamped at max_workers
# (no reduction). Tunable per call via `capped_worker_count`'s
# `min_rows_per_worker` argument.
comptime FANOUT_MIN_ROWS_PER_WORKER_DEFAULT: Int = 131072


# THE FAN-OUT CAP IS OPT-IN, DEFAULT OFF, AND ITS SWITCH IS THE CALLER'S.
#
# WHY DEFAULT-OFF. The TPC-H profile
# attributed q2/q5/q16 wall to worker busy-spin; this cap was built to shed it.
# A warm-context ABBA threshold sweep (q2/q5/q16 × {2K..131K rows/worker} vs the
# full pool) measured the cap as a WASH — ~0.96-1.00x, within run-to-run noise,
# and net-negative at some thresholds. The spin is the worker POOL's idle
# bounded-spin-then-park loop (`_worker_pthread_entry` / `drain_task_queue`),
# which fires in the un-dispatched idle workers REGARDLESS of a dispatch's
# width; reducing the fan-out does not quiet it and costs parallelism on the
# genuinely-parallel work. The effective lever is the pool park policy in
# `komira_async/runtime` (the moat), NOT this policy-layer knob. So the
# primitive lands opt-in-OFF (byte-and-wall-identical default) for a future
# pool-level scheduler that may combine a cardinality-aware fan-out with a
# quieter park policy. Engage it for measurement from the caller's own configuration.


def capped_worker_count(
    working_set_rows: Int,
    max_workers: Int,
    min_rows_per_worker: Int = FANOUT_MIN_ROWS_PER_WORKER_DEFAULT,
    trace: Bool = False,
) -> Int:
    """PURE fan-out cap: at most `max_workers`, and no more than
    `ceil(working_set_rows / MIN_ROWS_PER_WORKER)` ().

    The cap math ONLY — the opt-in ENABLE gate lives at the call site
    (the caller's own configuration, default OFF), so this function is
    configuration-independent + directly unit-testable. `row_count_hint`
    keys it, so it sizes to a source's working set with ONE heuristic.

    Answer-preserving for the SET of result rows: the return is always in
    `[1, max_workers]` (it can only REDUCE the pool), and worker count changes
    only HOW rows are sharded, never which rows survive (sink combines +
    corpus VALDUMP are order-independent). NOTE: parallel FLOAT reductions are
    non-associative, so a different worker count perturbs f64 agg sums at ~1e-10
    relative (row-count-identical, within DuckDB's rel_tol) — the same benign
    non-determinism any parallelism change carries.

    Args:
        working_set_rows: The operator's input-row estimate (a source's
            `row_count_hint()` / footer num_rows / `batch.num_rows()`). A value
            <= 0 means "unknown" -> NO cap (returns `max_workers`), so a source
            that cannot estimate its size keeps the full pool.
        max_workers: The full-pool fan-out (`engine_worker_count()`).
        min_rows_per_worker: The per-worker row threshold, for measurement
            sweeps. A value < 1 falls back to
            `FANOUT_MIN_ROWS_PER_WORKER_DEFAULT`.
        trace: Print one `[FANOUT-CAP]` line when the cap reduces the fan-out.

    Returns:
        `clamp(ceil(working_set_rows / MIN_ROWS_PER_WORKER), 1, max_workers)`
        when the count is known; `max_workers` otherwise. A large working set
        (>= max_workers * MIN_ROWS_PER_WORKER) returns `max_workers` unchanged,
        so genuinely-parallel scans/aggs/joins are never throttled.
    """
    if max_workers <= 1:
        return max_workers
    if working_set_rows <= 0:
        # Unknown cardinality -> conservative: keep the full pool.
        return max_workers
    var min_rpw = min_rows_per_worker
    if min_rpw < 1:
        min_rpw = FANOUT_MIN_ROWS_PER_WORKER_DEFAULT
    # ceil(working_set_rows / min_rpw)
    var capped = (working_set_rows + min_rpw - 1) // min_rpw
    if capped < 1:
        capped = 1
    if capped >= max_workers:
        return max_workers
    if trace:
        print(
            "[FANOUT-CAP] rows=", working_set_rows,
            " max_workers=", max_workers,
            " min_rpw=", min_rpw,
            " -> capped=", capped, sep="",
        )
    return capped


# =============================================================================
# PARALLEL FORK GRAIN — WAVE-SNAP, resolved at DISPATCH time
# =============================================================================
#
# WHAT SHIPS:
#
#     waves = ceil(rows / (workers * FORK_GRAIN_MAX_ROWS))     # >= 1
#     grain = ceil(rows / (workers * waves))                   # -> M = W*waves
#     morsels = ceil(rows / grain)
#     tasks   = min(morsels, workers)
#
#   ...and a DECLINE to the flat `FORK_GRAIN_MAX_ROWS` whenever that grain would
#   fall below `FORK_GRAIN_MIN_ROWS`. `parallel_fork_grain()` below is the whole
#   rule; it is PURE, it reads no environment, and every census site calls it
#   with its own `rows` and the ACTUAL pool width.
#
# ---------------------------------------------------------------------------
# ★ THE ONE THING THIS RULE DOES, AND THE MEASUREMENT THAT ISOLATED IT
# ---------------------------------------------------------------------------
#
# A fork of M morsels over W workers runs `ceil(M/W)` waves and the LAST wave is
# partial, so with k = M/W the pool occupancy over the fork is
#
#     util = k / ceil(k)                and util == 1 exactly when k is an integer.
#
# The rule chooses the grain that makes k an integer at the SMALLEST wave count
# that keeps the grain at or under the measured ceiling. That is all it does.
#
# ⚠ THIS WAS A COMPETING-HYPOTHESIS EXPERIMENT, NOT A DERIVATION, because the
# last two times a wave target was DERIVED it lost (`KOMIRA_MK_PROBE_RETILE`,
# and arm B of ``). The c5 grain curve is consistent with TWO stories
# and they were separated by pre-registering the arm on which they disagree in
# SIGN. Measured on `sdk/c5_inner_join_varchar` (probe 2,000,000 rows printed
# from the run, W=22, the benchmark host, one binary, byte-matched 6-byte env values via
# `KOMIRA_MK_PROBE_MORSEL`, position-balanced paired rounds, exact permutation;
# session control -13.23 ms p=0.484, sigma_d 22.5 raw / 12.8 robust):
#
#   grain    morsels   k      util     measured, + == the OTHER arm is slower
#   -------  -------  -----  ------    ---------------------------------------
#   016384       123  5.591   93.2%    SHIPPED (the reference)
#   015152       132  6.000  100.0%    +39.44 ms vs 016384, 0/10, p = 0.00195
#   014000       143  6.500   92.9%    -35.35 ms vs 015152, 0/14, p = 0.00012
#
#   H_util  "the driver is tail quantisation"  predicted +40 ms and a POSITIVE
#           sign on the second row.
#   H_mag   "the driver is grain magnitude, smaller is better" predicted +2..5 ms
#           and a NEGATIVE sign on the second row.
#
#   14,000 is 7.6% FINER than 15,152 and lost by 35 ms. H_mag is FALSIFIED on
#   its own discriminating arm; the pre-registration is `/tmp/PREREG_grain_record.md`
#   and `bench/results/grain_wave_snap/`.
#
# ⚠ MAGNITUDE IS REAL BUT SECOND-ORDER, and this rule deliberately does not
# chase it. At near-equal utilisation 8,192 beat 16,384 by 22.27 ms (util 92.8
# vs 93.2) and 14,000 beat 16,384 by ~8 ms in p50 (util 92.9 vs 93.2) — i.e.
# ~20 ms per halving, against ~35-40 ms for ONE step of the utilisation
# sawtooth. The rule's output is confined to `(MAX/2, MAX]`, so it collects the
# first-order term everywhere and never pays more than one octave of the second.
#
# ---------------------------------------------------------------------------
# WHY DISPATCH TIME AND NOT PLAN TIME (the maintainer's question, answered with lines)
# ---------------------------------------------------------------------------
# Both inputs are EXACT FACTS at the fork and neither is available as a fact
# earlier. `rows` is the materialised input row count and `workers` is
# `dispatcher.worker_count()` — the realised pool, never `num_physical_cores()`
# (). At every census site both are already in scope, on adjacent
# lines, with no plumbing:
#
#   join_multi_key_parallel.mojo:952  pool_n = dispatcher.worker_count()
#                              :958  grain, from `num_probe_rows`
#   compiler_parallel.mojo:980/1291   pool_n ... :988/1299 grain
#   hash_chain_parallel_build.mojo:495 pool_n  ... :502 grain
#   residual_semi_anti_parallel.mojo:874 pool_n ... :886-887 grain (two waves)
#   semi_join.mojo:744 / :961         dispatcher.worker_count() at the site
#   spill_parallel_insert.mojo:670 / :828   dispatcher.worker_count() at the site
#
# A plan-time estimator would substitute a CARDINALITY ESTIMATE for a number the
# fork already knows exactly, and would have to guess the pool width of a
# dispatcher that does not exist yet. It can only be worse, it adds an
# estimator to be wrong, and it buys nothing: the per-fork cost of this rule is
# two integer divides.
#
# ---------------------------------------------------------------------------
# THE CENSUS — 11 forks across 7 files (unchanged from the flat-grain landing)
# ---------------------------------------------------------------------------
# The census is defined by the MECHANISM (`morsels = ceil(rows / g)` then
# `tasks = min(morsels, pool)`), never by grepping a literal — a literal finds
# copies of an answer, not the question, and that search error is how
# `semi_join.mojo` (131,072, the worst member) survived the first pass.
#
#   file                            forks  role of the constant
#   ------------------------------  -----  ----------------------------------
#   compiler_parallel.mojo              2  GRAIN  -> wave-snap
#   residual_semi_anti_parallel.mojo    2  GRAIN  -> wave-snap (per wave)
#   join_multi_key_parallel.mojo        1  GRAIN  -> wave-snap
#   hash_chain_parallel_build.mojo      1  GRAIN  -> wave-snap
#   semi_join.mojo                      2  GRAIN  -> wave-snap
#   spill_parallel_insert.mojo          2  GRAIN  -> wave-snap
#   streaming_concat_parallel.mojo      1  TILE FLOOR — NOT a grain. UNCHANGED.
#
# ⚠ THE CONCAT SITE IS NOT A WAVE-SNAP SITE AND MUST NOT BE MADE ONE. It reads
# the constant as "a tile must carry at least this many rows"
# (`max_by_rows = total_rows // G`), which is the FLOOR concept, not the grain
# concept; its tile count is already capped by a pool-derived budget. It keeps
# `FORK_GRAIN_MAX_ROWS` verbatim, so that site is byte-identical.
#
# ⚠ AND `residual_semi_anti`'s TWO WAVES NO LONGER SHARE ONE NUMBER. That is the
# point, not a regression: the build side is a 6,001,215-row lineitem scan and
# the probe side a 75,871-row filtered residual, and one number cannot be right
# for both. Sharing 65,536 is what dispatched 2 tasks onto 22 workers. Each wave
# now snaps to its own row count.
#
# ---------------------------------------------------------------------------
# ⛔ ELIGIBILITY IS NOT GRAIN — HELD, EXACTLY WHERE IT SHIPPED
# ---------------------------------------------------------------------------
# `SEMI_PROBE_PARALLEL_MIN_ROWS` (131,072) and `_TILE_ENTRY_MIN_ROWS` (131,072)
# are UNCHANGED and are still applied BEFORE any grain is computed. NO INPUT
# THAT RUNS SERIAL TODAY BECOMES PARALLEL, on any pool, at any row count. Only
# the FAN of already-parallel work moves. The unmeasured [100K, 360K] band
# (board `GRAIN-UNMEASURED-BAND `) is why, and this repo has
# already MEASURED a +4.93% regression (`win_rank`, exact paired permutation
# p = 0.000263) from forking work too small to pay for its wakes.
#
# ---------------------------------------------------------------------------
# ★ THE I4 GUARD IS THE FLOOR, AND IT IS STATED IN ROWS PER TASK
# ---------------------------------------------------------------------------
# Doctrine I4: express a fan-out lever's eligibility in the QUANTITY the
# mechanism scales with. The mechanism here is a worker WAKE, which is repaid by
# ROWS THE WOKEN TASK OWNS. So the floor is a rows-per-task floor, and it is
# enforced by DECLINING rather than by clamping:
#
#     the rule engages  <=>  ceil(rows / workers) >= FORK_GRAIN_MIN_ROWS
#
# When it engages, `tasks == workers` and every task owns >= FORK_GRAIN_MIN_ROWS
# = 16,384 rows — 3.3x the >= 5,000-row break-even this file's own wake
# derivation asks for. When it declines, the grain is the flat
# `FORK_GRAIN_MAX_ROWS` and the behaviour is BYTE-IDENTICAL to the flat landing.
#
# ⚠ CLAMPING TO THE FLOOR IS THE MISTAKE THE DELETED RULE MADE, and it is the
# whole of that rule's q21 objection. `clamp(rows // (4W), 4096, 65536)` on
# q21's 75,871-row mark probe computes 862, clamps UP to 4,096, and dispatches
# 19 tasks — 14 extra wakes bought for a measured 1.37 ms (fork 7.057 -> 5.690).
# A clamp turns "this input cannot pay for the pool" into "fan it anyway". A
# DECLINE says the true thing. Under this rule q21's probe (75,871 < 22*16,384)
# declines and gets exactly today's 5 morsels / 5 tasks.
#
# ⚠ AND `MIN_MORSEL_ROWS_JOIN_PROBE = 4096` — the TIER clamp far above, a
# different constant — is NOT touched here. It is flagged in its own block as
# 82% of that block's own stated break-even; moving it in either direction
# without a measurement is the mistake that block exists to record.
#
# ---------------------------------------------------------------------------
# THREE SAFETY PROPERTIES THAT FALL OUT OF THE SHAPE, NOT OUT OF A REVIEW
# ---------------------------------------------------------------------------
#  1. THE GRAIN CAN ONLY GET FINER. `workers*waves >= rows/FORK_GRAIN_MAX_ROWS`
#     by construction, so `grain <= FORK_GRAIN_MAX_ROWS` always. The rule can
#     never re-create the 2-task cliff and can never exceed a value that has
#     been measured. The incumbent 65,536 is not reachable from here.
#  2. THE BLAST RADIUS IS STATED IN ROWS. Below `workers * FORK_GRAIN_MIN_ROWS`
#     (360,448 rows at W=22) the rule DECLINES and the output is the flat
#     constant, unchanged. Everything the flat landing measured below that row
#     count still holds byte-for-byte — INCLUDING the whole of the unmeasured
#     [100K, 360K] band that board `` carries.
#  2b. AND NOTHING SERIAL BECOMES PARALLEL, a STRICTER claim than (2), enforced
#     separately: `grain <= FORK_GRAIN_MAX_ROWS` means the rule's morsel count
#     is never BELOW the flat grain's, so the only way it could move a site off
#     its serial branch is where the flat count is exactly 1 — closed by the
#     `rows <= FORK_GRAIN_MAX_ROWS` early return in `parallel_fork_grain`. That
#     case was a MEASURED defect at an earlier floor (W=2, rows=16,384 -> 2
#     tasks); see the early return's comment.
#  3. NO OUTPUT CHANGES. Morsel geometry never changes WHICH rows come out, so
#     every join/semi/mark result is byte-identical. See the falsifier note.
#
# ⚠ ONE EXCEPTION TO (3), NAMED RATHER THAN BURIED: `spill_parallel_insert`
# folds f64 (sum/min/max) per key, so a different worker partition changes the
# REDUCTION ORDER and perturbs f64 sums at ~1e-16 relative per op. That is the
# same class the ratified F64 policy accepts (rel-tol 1e-9) and that
# `capped_worker_count` above already documents for a worker-count change; the
# ROW COUNT is unchanged. This is NOT a licence to widen the change into the
# AGG TIER: `MORSEL_TIER_AGG` / `agg_morsel_rows` are governed by hash-table
# CACHE FIT, which is a different question from fan, and they are untouched.
#
# ---------------------------------------------------------------------------
# ⛔ THIS RULE AND `capped_worker_count` ABOVE ARE DUALS. NEVER BOTH ON.
# ---------------------------------------------------------------------------
# `capped_worker_count` REDUCES workers so each owns >= 131,072 rows; this rule
# fans the FULL pool onto any input that can pay 16,384 rows per worker. On c5's
# 2,000,000-row probe the cap returns 16 where this rule wants 22. There is no
# conflict TODAY only because the cap is default-OFF behind
# the caller's own switch and measured a wash (~0.96-1.00x). If the cap is ever
# revived, the two must be reconciled DELIBERATELY, not stacked.
#
# ---------------------------------------------------------------------------
# ⚠ WHAT AN OUTPUT ORACLE CANNOT SEE, AND WHERE THE FALSIFIER LIVES
# ---------------------------------------------------------------------------
# A fork that yields 2 tasks and one that yields 22 return byte-identical
# results, so the TASK COUNT is the only assertion available. It is read back
# out of the kernel's own recorder (`grain_geometry.mojo`) by
# `tests/engine/test_fork_grain_wave_snap.mojo` (the geometry the formula
# predicts, at stated row counts and pool widths) and by the nine-leg
# `tests/engine/test_fork_grain_site_guards.mojo` (that every census site
# REACHES it). Never infer a morsel count from a row count; print it.
# =============================================================================

# THE CEILING. 16,384 is arm C of the pre-registered three-arm A/B
# (``) and the right-hand edge of the measured c5 plateau.
#
# ⚠ THE REASON NOT TO RAISE IT IS **SAFETY PROPERTY 1, NOT "UNPRICED"**
# (corrected in review). An earlier draft of this comment said
# raising it "lets the rule return a grain no A/B has priced". That is FALSE and
# is worth correcting rather than deleting: **22,727 HAS been priced and was the
# BEST arm on c5** (+43.13 ms, 0 of 21 rounds, p = 9.5e-07,
# `bench/results/c5_grain`), and it is ABOVE this ceiling. The real reason
# is structural: `grain <= FORK_GRAIN_MAX_ROWS` is what makes "the rule can only
# ever make a fork FINER" true, and THAT is what puts the 2-task cliff out of
# reach on every input and every pool. Raise the ceiling and the cliff becomes
# reachable again for large inputs — a safety argument, not a pricing one, and
# it survives the fact that a coarser value once measured well.
comptime FORK_GRAIN_MAX_ROWS: Int = 16_384

# THE FLOOR, IN ROWS PER TASK — AND IT IS DELIBERATELY EQUAL TO THE CEILING.
#
# ★ `min_rows == FORK_GRAIN_MAX_ROWS` AND `waves >= 2` ARE THE SAME STATEMENT,
# with one boundary point where they coincide harmlessly. Engaging requires
# `rows >= workers * 16,384`, and `waves = ceil(rows / (workers * 16,384))`, so
# every engaged input has `waves >= 1` and `waves == 1` at EXACTLY
# `rows == workers * 16,384` — where the snap returns 16,384 and `workers`
# morsels, i.e. BYTE-IDENTICAL to the flat grain. Above that point `waves >= 2`
# always. So the floor buys `k >= 2` (two full waves of work-stealing slack)
# everywhere it changes anything.
#
# ⚠ WHY NOT MAX/2 = 8,192, WHICH IS WHAT THE MEASUREMENT WOULD HAVE ALLOWED.
# Because 8,192 is a DERIVED constant in the one row band nobody has measured,
# and this change exists to reverse a doctrine that said "do not derive a wave
# target". Raising the floor to the ceiling is FREE at every cell that carries
# evidence — c5 (2,000,000), q21 build (6,001,215) and c5hc (20,000,000) all
# clear `22 * 16,384 = 360,448` and compute the IDENTICAL grain, and q21's
# 75,871-row stream declines either way — so it costs nothing measured and it
# buys three things:
#   * the whole unmeasured [100K, 360K] band (board ``) stays
#     BYTE-IDENTICAL to the flat landing, at W=22;
#   * the 11 -> 22 task DISCONTINUITY at `W * 8,192` disappears;
#   * `k >= 2`, so no engaged fork is ever a single wave with zero slack.
# Lower it LATER, WITH evidence from that band. Not before.
comptime FORK_GRAIN_MIN_ROWS: Int = 16_384


def parallel_fork_grain(
    rows: Int, workers: Int, min_rows: Int = FORK_GRAIN_MIN_ROWS
) -> Int:
    """THE FORK GRAIN — pure, dispatch-time, no environment, no globals.

    Snaps the grain so the morsel count is an exact multiple of the pool width,
    which makes the last wave FULL and the fork's occupancy 100% under the
    `util = k/ceil(k)` model. Declines to the flat ceiling when the input cannot
    give every worker `FORK_GRAIN_MIN_ROWS` rows.

    ★ THE MONOTONICITY THAT MAKES THIS SAFE. `grain <= FORK_GRAIN_MAX_ROWS`
    always, so `ceil(rows/grain) >= ceil(rows/FORK_GRAIN_MAX_ROWS)`: the rule's
    morsel count is NEVER BELOW the flat grain's. The only way it can change
    whether a site runs serially is at the boundary where the flat count is
    exactly 1 — and the `rows <= FORK_GRAIN_MAX_ROWS` early return closes
    precisely that case.

    Args:
        rows: The input row count THIS fork will partition. The exact
            materialised count, not an estimate.
        workers: The ACTUAL pool width — `dispatcher.worker_count()`, never
            `num_physical_cores()` (). A grain sized against cores
            the pool does not have sizes every downstream decision against
            workers that do not exist.
        min_rows: THE ROWS-PER-TASK FLOOR. Defaults to `FORK_GRAIN_MIN_ROWS`,
            which is EQUAL to the ceiling — see that constant for why, and note
            that `min_rows == FORK_GRAIN_MAX_ROWS` and `waves >= 2` are the same
            statement.
            It is a defaulted PARAMETER and not an environment probe — the shape
            `l1_chunk_admit(min_passes=)` / `l1_chunk_rows(force_admit=)` already
            use in this file, per the no-shipped-kill-switches
            directive. A sweep names it at a call site; an unset environment
            cannot reach it, so no production configuration can move the floor.
            Raising it above `rows // 1` declines every input, which is exactly
            the flat-grain arm and is how the A/B is driven from one binary.

    Returns:
        A grain in `(FORK_GRAIN_MAX_ROWS / 2, FORK_GRAIN_MAX_ROWS]` when the
        rule engages (the snap divides by at most one extra wave), and exactly `FORK_GRAIN_MAX_ROWS` when it declines — which is
        also what the degenerate inputs (`rows <= 0`, `workers <= 1`) get, since
        there is no fan-out to buy there.

    ⚠ `ceil(rows / grain)` is `workers * waves` for every input this rule
    engages on, but that is a PROPERTY, not an identity to rely on blindly: the
    round-trip can undershoot by one morsel when the morsel count approaches the
    grain itself, i.e. when `workers * waves` approaches the grain — at W=22
    that is `rows` on the order of `16,384^2 = 2.68e8`, a quarter-billion-row
    fork. Even there the occupancy is `(D-1)/D`. Call sites therefore keep computing
    `morsels = ceil(rows / grain)` and RECORD it; the tests assert the recorded
    value rather than the predicted one.
    """
    # No fan-out to buy: one worker, or nothing to partition.
    if workers <= 1:
        return FORK_GRAIN_MAX_ROWS
    if rows <= 0:
        return FORK_GRAIN_MAX_ROWS

    # ★ NOTHING THAT IS SERIAL TODAY MAY BECOME PARALLEL — ENFORCED HERE.
    # An input at or below the ceiling is ONE morsel under the flat grain, and
    # three census sites spell their eligibility test as `num_morsels <= 1`
    # (`compiler_parallel.mojo:993` / `:1308`, and the same shape elsewhere), so
    # for them "one morsel" IS "run serially". Without this line a snap can
    # return a grain BELOW the ceiling for such an input and split it in two.
    #
    # ⚠ THIS WAS A REAL DEFECT, NOT A HYPOTHETICAL (caught in review).
    # At `workers=2, rows=16,384` and a MAX/2 floor the rule engaged, computed
    # `waves=1, grain=8,192`, and produced 2 morsels -> 2 TASKS where the flat
    # grain produces 1 and the site runs serial.
    #
    # ⚠ AND IT IS REDUNDANT UNDER TODAY'S FLOOR, ON PURPOSE. With
    # `FORK_GRAIN_MIN_ROWS == FORK_GRAIN_MAX_ROWS` the floor check below already
    # declines every such input (`rows <= 16,384 < workers * 16,384` for any
    # `workers >= 2`). It is kept because the invariant it protects is stated as
    # a PROMISE in this file's header, and an invariant that is asserted rather
    # than enforced is one refactor away from gone — the same argument this
    # function already makes for re-checking the ceiling below. Lowering the
    # floor later must not silently reopen this.
    if rows <= FORK_GRAIN_MAX_ROWS:
        return FORK_GRAIN_MAX_ROWS

    # THE FLOOR, CHECKED FIRST AND AS A DECLINE. `ceil(rows/workers)` is the
    # rows every task would own at the full fan; if that cannot clear the floor,
    # this input cannot pay for the pool and the answer is the flat ceiling.
    # Written as a multiply so it cannot divide by a zero pool.
    var lo = min_rows
    if lo < 1:
        lo = 1
    if rows < workers * lo:
        return FORK_GRAIN_MAX_ROWS

    # The fewest waves that keep the grain at or under the ceiling.
    var span = workers * FORK_GRAIN_MAX_ROWS
    var waves = (rows + span - 1) // span
    if waves < 1:
        waves = 1

    # Snap: exactly `workers * waves` morsels, so the tail wave is full.
    var denom = workers * waves
    var grain = (rows + denom - 1) // denom
    if grain > FORK_GRAIN_MAX_ROWS:
        # Unreachable for `waves >= rows/span`, but a ceiling that is asserted
        # rather than enforced is a ceiling one refactor away from being gone.
        return FORK_GRAIN_MAX_ROWS
    if grain < 1:
        return 1
    return grain


# =============================================================================
# BULK-COPY FAN — a fan sized by BYTES MOVED and the POOL, never by a schema
# shape
# =============================================================================
#
# ★ THE RULE, IN ONE SENTENCE. A fork's task count must be derived from the WORK
# it will do and the POOL it will run on — never from a structural property of
# the data such as the column count, the batch count, or a partition constant.
#
# WHY THIS IS A CLASS AND NOT A SITE. The campaign has now found the same defect
# five times: a fan derived from a hand-typed grain (65,536 -> 2 tasks),
# `semi_join`'s 131,072, `_MARK_FILL_MORSEL`'s 262,144, and — the shape this
# function exists for — a fan whose task count IS the number of columns. Three
# dispatches in the tree spell their task count `num_cols`:
#
#   streaming_concat_parallel.mojo:_concat_impl     RecordBatch concat  <- fixed here
#   komira_csv/parallel_reader.mojo               CSV column concat
#   komira_parquet/parquet_parallel_writer.mojo   column ENCODE
#
# The first two move BYTES and are row-splittable, so this rule applies to both.
# The third is not in the class's remedy: a Parquet column encode is a
# compress-and-page pipeline over the whole column, so its unit of work cannot be
# row-split without changing the output bytes. It is named here so the next
# reader does not have to re-derive that it was considered.
#
# ★ WHY BYTES AND NOT ROWS (doctrine I4). Express a fan-out lever's eligibility
# in the quantity its MECHANISM scales with. `parallel_fork_grain` above fans a
# per-ROW kernel and its floor is therefore in rows. This one fans a MEMCPY,
# whose cost is bytes, and whose per-row cost varies 16x across the fixed-width
# types (INT8 -> DECIMAL128). A rows floor on a copy prices an INT8 column as if
# it were an INT64 and fans it 8x too hard.
#
# ★ WHY MORE CONCURRENCY HELPS A COPY AT ALL — and what would falsify it. A
# large columnar copy is often called "DRAM-bandwidth-bound", and if that were
# true here more workers could not help. On the measurement target it is not:
# per-core copy throughput is capped by the ~10 line-fill buffers each core can
# keep outstanding (`10 x 64 B / ~85 ns ~= 7.5 GB/s`), while the socket sustains
# ~55-60 GB/s — so saturation needs ~8 cores, and a 2-task fan reaches ~25% of
# the achievable rate. The number of tasks it takes to saturate is
# `socket_bandwidth / per_core_bandwidth`, and that ratio is a property of the
# MACHINE, not of the query. ⚠ ON A DESKTOP IT IS ~3, WHICH IS WHY THE
# ROW-RANGE A/B READ FLAT: it was measured on an i7-14700K (dual-channel DDR5,
# ~20-25 GB/s per core), where 2-3 tasks already saturate and there is nothing
# for a wider fan to collect. That verdict was correct FOR THAT MACHINE and does
# not transfer to a many-core server socket. See
# an internal agent note.
#
# ⚠ SO THE FALSIFIER IS NOT "L3 MISSES FALL". Splitting a copy across more
# workers moves the SAME bytes and therefore takes the SAME number of compulsory
# misses; what changes is how many are outstanding at once. A wall win with flat
# L3 misses is the PREDICTED result here, not a contradiction. The claim that
# would be falsified by a flat wall is "the copy is latency-bound at the
# incumbent fan", and the discriminating measurement is the fan-vs-wall CURVE.
#
# ⛔ THIS IS A MOVE, NOT A DELETE. Fanning a copy does not stop the copy. Where a
# concat's output is immediately re-split into morsels, DELETING the pair is
# strictly better than fanning either half, and this rule must not be read as a
# reason not to.
#
# ★ AND HERE IS THE CASE WHERE THE MOVE WAS TAKEN ANYWAY, RECORDED SO THE NEXT
# READER DOES NOT RE-DERIVE IT AND LAND THE OTHER WAY (LEVER A). At
# the c5hc join the rule's own precondition is only PARTLY met: the concatenated
# batch has three consumers and only one of them re-morselizes — pricing tiles
# [0, n) and the surviving Int64 gather both address it by output-row index. The
# DELETE was priced at ~1000 lines across 8 files, and it lands a new (batch,
# row) addressing mode inside `join_multikey_kernel` — 483 ms at 0.9927
# occupancy, the most saturated fork in the query, whose response to a packed
# index nobody has measured — with a plausible WRONG ANSWER as its failure mode.
# The MOVE (making STRING columns row-splittable, below) is ~600 lines in two
# files behind a kill switch, reuses an existing byte-equivalence fixture, and
# applies to all 14 `concat_record_batches_column_parallel` call sites rather
# than to one join. It does not foreclose the delete; it PRICES IT OUT — post-
# LEVER-A the delete's residual prize is ~0.075 ms/line, the worst rate on the
# board. The rule above is correct; this is the case where the move is the right
# trade anyway.

# THE PER-TASK BYTE FLOOR. 128 KiB.
#
# NOT A NEW CONSTANT: it is `FORK_GRAIN_MIN_ROWS (16,384) x 8 B`, i.e. the fork
# grain's own rows-per-task floor priced at the dominant fixed-width column type.
# For an 8-byte column this rule and `parallel_fork_grain` therefore admit at the
# SAME point; narrower types get proportionally fewer tiles, which is the whole
# correction, and wider types (DECIMAL128) proportionally more.
#
# WHAT IT BUYS, in the unit the mechanism is stated in: at the ~7.5 GB/s per-core
# copy rate above, 128 KiB is ~17 us of work against a worker wake measured in
# single-digit microseconds — a >=5x repayment. Requiring at least TWO tiles
# before the path engages means the smallest input this rule can admit moves
# 256 KiB in its widest column.
comptime COPY_TILE_MIN_BYTES: Int = 131_072


def parallel_copy_tiles(
    widest_unit_bytes: Int,
    n_splittable: Int,
    n_unsplittable: Int,
    workers: Int,
    min_bytes: Int = COPY_TILE_MIN_BYTES,
) -> Int:
    """Tiles per splittable unit for a bulk-copy fan. PURE; reads no environment.

    A copy dispatch has two kinds of unit: ones that can be split by row range
    (a tile writes a disjoint destination byte slice) and ones that cannot. The
    unsplittable ones take one task each off the top; the rest of the pool is
    divided over the splittable ones.

    ⚠ WHAT COUNTS AS SPLITTABLE IS THE CALLER'S ANSWER, AND THIS DOCSTRING GOT
    IT WRONG. It used to say a variable-width column "cannot"
    be split because it "would need a per-row byte-offset pre-pass". That is
    true of a GATHER — output row i's destination byte offset depends on the
    lengths of all i-1 rows before it — and FALSE of a CONCAT, which lays its
    inputs end to end so a tile needs only a per-BATCH prefix sum plus THREE
    Int32 loads per (tile, batch) pair. `streaming_concat` now passes its
    STRING/BINARY columns as SPLITTABLE and prices them by their PAYLOAD bytes;
    see `_concat_string_column_into_range`. The `komira_csv` column concat has
    the same shape and can inherit it. ⛔ THE PARQUET COLUMN ENCODE STILL
    CANNOT: it is a compress-and-page pipeline over the whole column, so
    row-splitting it changes the output bytes. Do not let "variable-width is
    splittable now" leak into that third site.

        budget = workers - n_unsplittable
        tiles  = min( budget // n_splittable ,           # POOL-derived
                      widest_unit_bytes // min_bytes )   # WORK-derived floor

    ★ `budget // n_splittable` FLOORS, IT DOES NOT CEIL. `ceil` is the obvious
    spelling and it is wrong: it can return a total task count ABOVE the pool
    width, which runs a second wave containing a handful of tasks. At W=22 with
    4 fixed + 1 string columns, ceil gives 6 tiles = 25 tasks (occupancy 25/44 =
    57%) where floor gives 5 tiles = 21 tasks (95%). Flooring makes
    `tiles * n_splittable + n_unsplittable <= workers` hold by construction, so
    an engaged fan is always exactly ONE full wave — and for a copy that is
    optimal, because equal-byte tiles are equal-cost and there is no straggler
    for a second wave to absorb.

    ⚠ AN UNSPLITTABLE UNIT IS A STRAGGLER and this rule does not fix that. A
    1.8M-row column that takes one task next to twenty 128 KiB tiles IS the
    fork's wall. That used to describe every STRING column and no longer does
    (see the note above); it still describes anything a caller declares
    unsplittable, and it bounds what this rule can buy on such a batch.

    ⚠ AND EQUAL-BYTE TILES ARE EQUAL-COST ONLY WITHIN ONE UNIT. Every splittable
    unit gets the SAME tile count, which was exact while all of them were
    fixed-width columns of the same batch. With a 1.12 GB STRING column and a
    160 MB INT64 column both splittable at 10 tiles each, the string tiles are
    112 MB and the int64 tiles 16 MB — 7x apart. Byte-PROPORTIONAL allocation is
    ~15 lines and is the correct form, but it revises the invariant this
    function's `floor` argument rests on and needs its own falsifier; under
    bandwidth saturation it changes little. Left as a separate card rather than
    smuggled in here.

    Returns:
        The number of row-range tiles EACH splittable unit should be cut into.
        **1 means DECLINE** — the caller keeps its incumbent one-task-per-unit
        fan, byte-for-byte. Decline happens when the pool has no room
        (`budget < 2 * n_splittable`, which includes every case where the unit
        count already meets or exceeds the pool width) or when the work is too
        small to repay a second wake (`widest_unit_bytes < 2 * min_bytes`).
    """
    if workers <= 1:
        return 1
    if n_splittable <= 0:
        return 1
    if widest_unit_bytes <= 0:
        return 1
    var lo = min_bytes
    if lo < 1:
        lo = 1

    var budget = workers - n_unsplittable
    if budget < n_splittable:
        # Not even one task per splittable unit is left after the unsplittable
        # ones. Widening here would over-subscribe the pool; decline.
        return 1
    var by_pool = budget // n_splittable

    # THE WORK FLOOR, AS A DECLINE RATHER THAN A CLAMP. Clamping "this input
    # cannot pay for the pool" into "fan it anyway" is the mistake
    # `parallel_fork_grain`'s header records; the answer is to return 1 and let
    # the caller keep the fan it had.
    var by_work = widest_unit_bytes // lo

    var tiles = by_pool
    if by_work < tiles:
        tiles = by_work
    if tiles < 2:
        return 1
    return tiles


