# =============================================================================
# MorselSizingPolicy -- rows per morsel, a pure function of the host profile
# =============================================================================
#
# The morsel size of a segment is chosen by the host when it lowers the segment
# and is recorded in the physical plan (`SegmentDescPod.morsel_rows`); nothing
# downstream re-derives it. The choice is a pure function of
# `(host_profile, segment, schema)`:
#
#     morsel_rows(schema, tier) = clamp(
#         l2_share_budget / row_byte_width(schema) * tier_multiplier,
#         MIN_for_tier,
#         MAX_for_tier,
#     )
#
# where `l2_share_budget` is a fraction of the per-worker share of the binding
# L2 instance (`HardwareProfile.effective_e_core_l2_per_worker`) and the tier is
# read off the segment's shape (`segment_morsel_tier`). There is no environment
# override and no producer statistic in the formula: two hosts with equal
# profiles record equal morsel sizes for equal segments.
#
# Four tiers:
#   * AGG        -- 1.0x -- hash-table cache fit
#   * JOIN_PROBE -- 1.0x with a stricter MIN clamp
#   * DEFAULT    -- 2.0x -- general source / filter pipelines
#   * BULK_SCAN  -- 8.0x -- a scan that only collects
#
# The fork grain and the fan-out cap are not in this file: they are decided at
# dispatch time from exact facts (the input's size and the pool), not recorded.
# The L1-chunk predicate is in `l1_chunk_sizing.mojo`.
# =============================================================================

from komira_arrow.schema import Schema
from komira_engine_runtime.hardware import (
    HardwareProfile,
    E_CORE_L2_BUDGET_NUM,
    E_CORE_L2_BUDGET_DEN,
)
from komira_engine_runtime.host_profile import HostProfile
from komira_engine_runtime.l1_chunk_sizing import (
    L1_CHUNK_MIN_ROWS,
    L1_CHUNK_BUDGET_NUM,
    L1_CHUNK_BUDGET_DEN,
    L1_CHUNK_RESERVE_NUM,
    L1_CHUNK_RESERVE_DEN,
    L1_CHUNK_MIN_FOLD_PASSES,
    L1_CHUNK_STATE_UNKNOWN,
    L1_CHUNK_DECLINE,
    l1_chunk_admit,
    l1_chunk_grain_round,
)
from komira_physical_plan.physical_plan import (
    SegmentDescPod,
    SOURCE_PARQUET,
    OP_FILTER,
    OP_JOIN_PROBE,
    SINK_AGG,
    SINK_COLLECT,
    SINK_JOIN_PROBE,
)

# =============================================================================
# MorselTier sentinels (UInt8) -- enum tag for the per-tier accessors
# =============================================================================
#
# Pattern mirrors the existing in-tree `SOURCE_PARQUET` (logical_plan.mojo)
# and `PLACEMENT_FIXED` (async/runtime.mojo) sentinels — UInt8 comptime
# constants are the canonical Mojo enum-tag shape until a richer
# tag struct is needed.
#
# The four tiers map to the empirical 3-band distribution of the prior
# hardcoded morsel sizes (memo §1.B.4):
#     * AGG        ~ 4096 / 8192 rows -- L1d-fit, HT-probe hot loop
#     * JOIN_PROBE ~ 4096 rows hard floor -- segment-combine queue depth
#     * DEFAULT    ~ 65536 rows -- general-purpose source / filter scans
#     * BULK_SCAN  ~ 262144 rows -- MapOp / source-only with no agg

comptime MORSEL_TIER_AGG: UInt8 = 0
comptime MORSEL_TIER_JOIN_PROBE: UInt8 = 1
comptime MORSEL_TIER_DEFAULT: UInt8 = 2
comptime MORSEL_TIER_BULK_SCAN: UInt8 = 3


# =============================================================================
# Clamps -- per-tier MIN / MAX rows
# =============================================================================
#
# Lower-bound rationale (memo §3):
#   * MIN_MORSEL_ROWS_DEFAULT = 1024 — dispatch overhead becomes a
#     meaningful fraction below ~1K rows; matches v0.3 `MIN_MORSEL_ROWS`
#     and DuckDB's `STANDARD_VECTOR_SIZE * 0.5`.
#   * MIN_MORSEL_ROWS_JOIN_PROBE = 4096 — probe-side morsels currently
#     run at 4096 rows hardcoded; the stricter MIN preserves queue-depth
#     dynamics on the segment-combine boundary.
#
# Upper-bound rationale:
#   * MAX_MORSEL_ROWS_DEFAULT = 131072 — too-large morsels stop fitting
#     in L2 on the inter-operator boundary (sink ingestion -> next-op
#     slab append). Inherited from v0.3 `MAX_MORSEL_ROWS`.
#   * MAX_MORSEL_ROWS_BULK_SCAN = 524288 — bulk-scan path's per-morsel
#     fixed cost amortizes over more rows; the prior hardcoded 262144
#     site established 256K as the empirical sweet spot, so 512K gives
#     the 8.0x multiplier headroom on machines with very narrow rows
#     (e.g. single-i64 columns at SF10 bench scale).

comptime MIN_MORSEL_ROWS_DEFAULT: Int = 1024
comptime MIN_MORSEL_ROWS_JOIN_PROBE: Int = 4096
comptime MAX_MORSEL_ROWS_DEFAULT: Int = 131072
comptime MAX_MORSEL_ROWS_BULK_SCAN: Int = 524288


# =============================================================================
# Tier multipliers (memo §4)
# =============================================================================

comptime TIER_MULT_AGG: Float64 = 1.0
comptime TIER_MULT_JOIN_PROBE: Float64 = 1.0  # stricter MIN clamp does the work
comptime TIER_MULT_DEFAULT: Float64 = 2.0
comptime TIER_MULT_BULK_SCAN: Float64 = 8.0



# =============================================================================
# AggFoldConfig -- the grouped-aggregation FOLD ADMISSION arms, as a TYPED VALUE
# =============================================================================
#
# ⛔ RULING R7 `CONFIG-IS-FLAGS-NOT-ENV` (maintainer 2026-09-14): a binary's
# configuration is specified with command-line FLAGS, never environment
# variables. This struct is the value a flag resolves INTO, so that a
# fold-admission arm can be selected by `runner --agg-fold=...` instead of by
# `KOMIRA_AGG_*`.
#
# ⭐ WHY A VALUE AND NOT AN ENV READ, stated as the mechanism rather than the
# rule: `getenv` returns the SAME BYTES ("") for NEVER SET and for SET EMPTY, so
# an env-gated A/B cannot represent "the default" and "explicitly the default" as
# two distinguishable arms. The 2026-09-14 aggregation pre-registration
# (`bench/results/agg_family_split_0914/`) registered exactly that table --
# DEF(unset) == SETON(=1) -- and it was unrunnable as written for this reason.
# With a flag, DEF and SETON produce the same ENGINE STATE on purpose, and the
# run RECORD still distinguishes them (the runner echoes `src=default|flag`), so
# their equality becomes a MEASURED control instead of a structural assumption.
#
# ⚠ THIS STRUCT IS CONFIG, NOT POLICY. It carries no defaulting intelligence and
# no env read of its own -- whoever constructs it decides. That is deliberate:
# a read-site default is what makes an unsupplied value look supplied, which
# `validate_param_decls` refuses for required params elsewhere in the tree.


struct AggFoldConfig(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    """Per-session admission arms for `_mono_fold_eligible`'s specialised fold.

    One field per ADMISSION GATE, never one per experiment: an arm is a value of
    this struct, so adding an experiment does not add a configuration channel.

    Fields:
      * `intfold` -- the INTEGER half of the envelope (`AGG_SUM_I64` / `AGG_AVG_F64`
        over an int32/int64 source), landed. Shipped default ON.
      * `minmaxfold` -- the MIN/MAX half (`MIN_F64`/`MAX_F64`/`MIN_I64`/`MAX_I64`).
        ⛔ **NOT IMPLEMENTED.** `_mono_fold_eligible` still declines every one of
        those ops unconditionally; this field is the arm the L-MINMAXFOLD
        experiment will drive IF its P0 funds it, and until that lands setting it
        changes NOTHING. It is declared here so the flag surface does not have to
        change later, and it defaults OFF so the shipped default is today's
        behaviour.
    """

    var intfold: Bool
    var minmaxfold: Bool

    def __init__(out self, intfold: Bool = True, minmaxfold: Bool = False):
        """Defaults are the SHIPPED behaviour as of 2026-09-14: INTFOLD on,
        MINMAXFOLD off (and inert). A caller that wants the incumbent arm should
        say so explicitly rather than rely on these staying put."""
        self.intfold = intfold
        self.minmaxfold = minmaxfold


# =============================================================================
# MorselSizingPolicy
# =============================================================================


struct MorselSizingPolicy(Copyable, Movable, Deinitable):
    """Auto-derive morsel size per (schema, operator-tier).

    Built from the host profile (`for_host`) when a segment is lowered;
    consulted per call while lowering (per-call
    cost is microseconds, so no caching needed).

    The struct is POD (~80 bytes — one `HardwareProfile`); Copyable so
    it can be passed by value into helpers that need it without lifetime
    plumbing.

    Public API (the only methods callers should reach for):
        * `morsel_rows(schema, tier)` — the formula + clamps.
        * `agg_morsel_rows(schema)` / `join_probe_morsel_rows(...)` /
          `default_morsel_rows(...)` / `bulk_scan_morsel_rows(...)` —
          convenience accessors over the `MORSEL_TIER_*` sentinels.

    NO env-var override (memo §9 Q4 ratified — auto-derive is the single
    source of truth).
    """

    var profile: HardwareProfile
    # ⚠ THE NAME OF THIS STRUCT IS NOW TOO NARROW, AND THAT IS A KNOWN DEBT.
    # `MorselSizingPolicy` is the ONLY per-session value that travels from
    # `EngineContext` to operator construction -- it is copied out of the context
    # at the exec entry points (`ctx.sizing_policy().copy()`) and threaded through
    # ~254 signatures to every leaf. Anything the session must tell an OPERATOR
    # has to ride it or invent a second channel across all 254. So it carries
    # session TUNING, not only sizing; this file already reads six env levers for
    # the same reason. Renaming it to `SessionTuning` is a mechanical 254-site
    # change and belongs in its own change, NOT bundled with a lever.
    var agg_fold: AggFoldConfig

    def __init__(
        out self,
        var profile: HardwareProfile,
        agg_fold: AggFoldConfig = AggFoldConfig(),
    ):
        """Construct from a caller-supplied `HardwareProfile` (taken by value).

        `agg_fold` DEFAULTS to the shipped arms, so every existing construction
        site is unchanged by its addition. `EngineContext` overwrites it when a
        flag asks for a non-default arm."""
        self.profile = profile^
        self.agg_fold = agg_fold

    @staticmethod
    def for_host(host: HostProfile) -> MorselSizingPolicy:
        """The policy of a host: its recorded hardware profile and the shipped
        fold arms. Reads only `host`; it never probes the machine."""
        return MorselSizingPolicy(host.hardware.copy(), AggFoldConfig())

    @staticmethod
    def from_defaults() -> MorselSizingPolicy:
        """Construct from the Apple-Silicon-shaped fallback profile.

        For tests that want a policy without a host profile. A host lowers
        with `for_host`.
        """
        return MorselSizingPolicy(
            HardwareProfile.defaults(), AggFoldConfig()
        )

    # --- Formula ----------------------------------------------------------

    def morsel_rows(self, schema: Schema, tier: UInt8) -> Int:
        """Auto-derived rows per morsel for `schema` at the given `tier`.

        ONE formula, no env gate (memo §9 Q4):

            l2pw   = profile.effective_e_core_l2_per_worker()   # L2 / cpusperl2
            budget = l2pw * E_CORE_L2_BUDGET_NUM / E_CORE_L2_BUDGET_DEN  # x0.5
            base   = budget / max(row_width_bytes(schema), 1)
            sized  = base * tier_multiplier(tier)
            return clamp(sized, MIN_for_tier, MAX_for_tier)

        The `x0.5` reserves half the share for operator state (hash-table
        heads, accumulator slots, dispatch struct fields) — the same reserve
        the v0.3 `HardwareProfile::optimal_agg_morsel_rows` expressed as `/2`.

        WHY THE L2 SHARE AND NOT L1d. The morsel must be residency-safe on
        EVERY core, and the smallest per-worker L2 share is the binding
        constraint (macOS cannot pin threads, so there is ONE global grain and
        it has to fit the smallest tier). `l1d_cache_bytes` is the homogeneous
        `hw.l1dcachesize` sysctl — on heterogeneous Apple Silicon it reports
        the SMALLER E-core L1d, and on the Broadwell bench box it is 32 KiB,
        i.e. a 16 KiB budget, which is 8x tighter than the L2 share. Sizing
        off it was the bug; see the module section above for what correcting
        it measured.

        Worked values. M3 Ultra: E-L2 4 MiB / cpusperl2 4 -> l2pw 1 MiB ->
        budget 512 KiB; a narrow i64 key (8 B/row) gives base 65536, so AGG
        (1.0x) is 65536 and DEFAULT (2.0x) clamps to MAX 131072. the benchmark host:
        L2 256 KiB, divisor 1 -> budget 128 KiB -> base 16384 at 8 B/row.
        """
        var row_w = schema.row_width_bytes()
        if row_w < 1:
            row_w = 1
        # L2-per-worker budget, half reserved for HT / operator state.
        var l2pw = self.profile.effective_e_core_l2_per_worker()
        var budget = (l2pw * E_CORE_L2_BUDGET_NUM) // E_CORE_L2_BUDGET_DEN
        var base = budget // row_w
        var mult = _tier_multiplier(tier)
        var sized = Int(Float64(base) * mult)
        var min_rows = _tier_min(tier)
        var max_rows = _tier_max(tier)
        return _clamp(sized, min_rows, max_rows)

    # --- L1-CHUNK sizing (DEFAULT-ON; no enable gate) -----

    def l1_chunk_budget_bytes(
        self, resident_state_bytes: Int, base_bytes: Int = 0
    ) -> Int:
        """The per-chunk DATA budget in bytes, or 0 if L1 sizing is declined.

        `budget - max(resident_state_bytes, budget/4)`, where `budget` is
        `L1_CHUNK_BUDGET_NUM/DEN x l2_cache_bytes` (2 x per-core L2 = 512 KiB on
        the Broadwell target). See the "(a) SIZE" module section for why the
        base moved off `l1d_cache_bytes` and why the cache level is stated as
        CONTESTED rather than asserted. `base_bytes > 0` replaces the whole base
        for a sweep (was `KOMIRA_L1_CHUNK_BYTES`, deleted — it gated
        behaviour, so it is a parameter now, not an environment).

        THREE-STATE `resident_state_bytes` (this is the `est_groups < 0` fix):
          * `>= 0`  — a real estimate. The reserve grows to hold it, and a state
                      that meets or exceeds the budget returns 0 (DECLINE) —
                      the high-cardinality group-by guard, unchanged in effect.
          * `< 0`   — `L1_CHUNK_STATE_UNKNOWN`. ABSTAIN: the reserve keeps its
                      1/4 floor and residency expresses no opinion either way.
                      It used to be spelled `0`, i.e. "the table is empty, so
                      definitely admit" — a guard whose failure mode is ADMIT.
                      Admission now rests on the amortisation conjunct instead
                      (`l1_chunk_admit`), which is the one that discriminates.

        Returns 0 when the base is implausible (< 1 KiB) or when a KNOWN
        `resident_state_bytes >= base`.
        """
        var base = base_bytes
        if base < 1:
            base = (
                self.profile.l2_cache_bytes * L1_CHUNK_BUDGET_NUM
            ) // L1_CHUNK_BUDGET_DEN
        if base < 1024:
            # Implausible / failed hardware probe -> no cache-derived answer.
            return 0
        var reserve = (base * L1_CHUNK_RESERVE_NUM) // L1_CHUNK_RESERVE_DEN
        # A negative value is UNKNOWN and can never exceed the floor, so the
        # abstain case falls out of the same comparison — no extra branch.
        if resident_state_bytes > reserve:
            reserve = resident_state_bytes
        if reserve >= base:
            return 0
        return base - reserve

    def l1_chunk_rows(
        self,
        live_row_width_bytes: Int,
        resident_state_bytes: Int,
        fold_passes: Int,
        force_admit: Bool = False,
        min_passes: Int = L1_CHUNK_MIN_FOLD_PASSES,
        forced_rows: Int = 0,
    ) -> Int:
        """Rows per chunk sized so the LIVE columns are cache-co-resident —
        AFTER the admission predicate has said this query should be chunked.

        The two questions are answered in order and separately: `l1_chunk_admit`
        answers "chunk at all?" (amortisation + residency), and only then does
        the live-width divisor answer "how big?". Read the "(a) SIZE" and "(b)
        WHETHER" module sections before changing either.

        Args:
            live_row_width_bytes: Sum, over ONLY the columns this operator
                touches, of the bytes the fold reads per row. Supplied by
                `komira_parquet.materialize_parquet.live_row_width_bytes`,
                which prices dict-encoded and variable-width columns from the
                Parquet footer instead of the 32 B row-store estimate. This is
                the maintainer's "size from the combination of columns actually being
                used", and it is kept — it answers (a) correctly. It CANNOT
                answer (b): h2o/q02's live set is NARROWER than q1's, so width
                alone hands the cell that must not be chunked the bigger chunk.
            resident_state_bytes: The operator's own residents that are NOT
                proportional to the chunk size (hash table + accumulators).
                `L1_CHUNK_STATE_UNKNOWN` (any negative) means "no estimate" ->
                residency ABSTAINS. 0 means "measured empty", which is NOT the
                same thing and no longer conflated with it.
            fold_passes: How many times the fold walks the chunk's rows — the
                aggregate count for the untyped grouped agg. <= 0 == unknown,
                which never amortises and therefore never admits.
            force_admit: BYPASS the admission predicate. MEASUREMENT ONLY, and
                it is a defaulted PARAMETER rather than an environment probe
                (was `KOMIRA_L1_CHUNK_FORCE`, deleted) so no
                production configuration can reach it — a caller has to write
                it. Use it to price what the predicate is DECLINING on a cell;
                never to land a result. A forced arm with a dead budget still
                has no size to offer unless `forced_rows` supplies one.
            min_passes: The amortisation threshold, forwarded verbatim to
                `l1_chunk_admit`. Defaults to `L1_CHUNK_MIN_FOLD_PASSES` (4),
                which is FITTED TO FOUR MEASURED POINTS. It is here so the
                {2,3,4,6,8} sweep can be driven from the ONE production seam
                (`materialize_parquet.agg_leaf_morsel_rows`) by naming an
                argument, rather than only from a direct call to this method —
                without it the parameter existed but no caller on the shipped
                path could reach it, which is not a knob, it is a comment.
            forced_rows: When > 0, overrides the computed SIZE (verbatim,
                un-clamped, so a sweep can probe outside [MIN, MAX]
                deliberately). 0 (the default) means "use the computed size".
                It does NOT bypass ADMISSION — `force_admit` does that.

        Returns:
            `grain_round_down(budget / live_width)` in `[MIN, MAX]`, or
            `L1_CHUNK_DECLINE` (0) when there is no honest answer: not admitted
            (too few passes / state exceeds the budget / bad probe), one row
            exceeds the budget, or the computed count falls below
            `L1_CHUNK_MIN_ROWS`. A 0 return means the CALLER KEEPS ITS EXISTING
            SIZING.

        ⚠ `forced_rows` IS THE SURVIVING NULL CONTROL. `forced_rows=122880` puts
        the row-group-sized chunk back into the SHIPPED binary and must
        reproduce the pre-flip wall (80.6 ms on q1). Without it the default
        path's -18% is an assertion measured across two binaries, which is the
        exact shape that produced four fabricated results in this campaign. Do
        not delete it without a replacement one-binary control.
        """
        var budget = self.l1_chunk_budget_bytes(resident_state_bytes)
        if not l1_chunk_admit(fold_passes, budget, min_passes):
            if not force_admit:
                return L1_CHUNK_DECLINE
            # FORCE: reproduce the historical override sweeps by pricing a cell
            # the predicate declines. A forced arm with a dead budget still has
            # no size to offer unless ROWS supplies one.
            if budget <= 0 and forced_rows < 1:
                return L1_CHUNK_DECLINE
        if forced_rows > 0:
            return forced_rows
        var w = live_row_width_bytes
        if w < 1:
            w = 1
        if w > budget:
            # One row does not fit (the 4 KB-string-column case) -> DECLINE.
            return L1_CHUNK_DECLINE
        return l1_chunk_grain_round(budget // w)

    # --- Per-tier convenience accessors -----------------------------------

    @always_inline
    def agg_morsel_rows(self, schema: Schema) -> Int:
        """Shortcut for `morsel_rows(schema, MORSEL_TIER_AGG)`."""
        return self.morsel_rows(schema, MORSEL_TIER_AGG)

    @always_inline
    def join_probe_morsel_rows(self, schema: Schema) -> Int:
        """Shortcut for `morsel_rows(schema, MORSEL_TIER_JOIN_PROBE)`."""
        return self.morsel_rows(schema, MORSEL_TIER_JOIN_PROBE)

    @always_inline
    def default_morsel_rows(self, schema: Schema) -> Int:
        """Shortcut for `morsel_rows(schema, MORSEL_TIER_DEFAULT)`."""
        return self.morsel_rows(schema, MORSEL_TIER_DEFAULT)

    @always_inline
    def bulk_scan_morsel_rows(self, schema: Schema) -> Int:
        """Shortcut for `morsel_rows(schema, MORSEL_TIER_BULK_SCAN)`."""
        return self.morsel_rows(schema, MORSEL_TIER_BULK_SCAN)

    # NOTE: the fan-out cap is a FREE function (`capped_worker_count`) + an
    # opt-in gate (`fanout_cap_enabled()`), NOT a method on this struct — it is
    # independent of the HardwareProfile and applied centrally in
    # `execute_collect_morsel_sink` off a source's `row_count_hint()`. See the
    # FAN-OUT CAP module header for the DEFAULT-OFF verdict + rationale.


# =============================================================================
# Internal helpers
# =============================================================================


@always_inline
def _tier_multiplier(tier: UInt8) -> Float64:
    """Tier multiplier (memo §4)."""
    if tier == MORSEL_TIER_AGG:
        return TIER_MULT_AGG
    if tier == MORSEL_TIER_JOIN_PROBE:
        return TIER_MULT_JOIN_PROBE
    if tier == MORSEL_TIER_DEFAULT:
        return TIER_MULT_DEFAULT
    if tier == MORSEL_TIER_BULK_SCAN:
        return TIER_MULT_BULK_SCAN
    # Defensive: unknown tier -> DEFAULT (matches memo §4 default fallback).
    return TIER_MULT_DEFAULT


@always_inline
def _tier_min(tier: UInt8) -> Int:
    """Per-tier MIN clamp."""
    if tier == MORSEL_TIER_JOIN_PROBE:
        return MIN_MORSEL_ROWS_JOIN_PROBE
    return MIN_MORSEL_ROWS_DEFAULT


@always_inline
def _tier_max(tier: UInt8) -> Int:
    """Per-tier MAX clamp."""
    if tier == MORSEL_TIER_BULK_SCAN:
        return MAX_MORSEL_ROWS_BULK_SCAN
    return MAX_MORSEL_ROWS_DEFAULT


@always_inline
def _clamp(value: Int, lo: Int, hi: Int) -> Int:
    """Clamp `value` into `[lo, hi]`. Mirrors Rust's `.clamp()`."""
    if value < lo:
        return lo
    if value > hi:
        return hi
    return value


# =============================================================================
# THE JOIN-PROBE GRAIN SEAM — the tier that existed and was never consulted
# =============================================================================
#
# `materialize_join`'s in-mem probe driver sized its morsels with
# `policy.default_morsel_rows(probe_schema)` — the DEFAULT tier, whose MIN clamp
# is `MIN_MORSEL_ROWS_DEFAULT = 1024` — on a JOIN PROBE. The JOIN_PROBE tier
# (`MIN_MORSEL_ROWS_JOIN_PROBE = 4096`) exists for exactly that site and had
# ZERO production consumers: a census of the whole tree found only its own unit
# tests and a passthrough accessor on `EngineContext` that nothing called. This
# function is the tier's first production use. NO CONSTANT WAS MOVED.
#
# MEASURED, the benchmark host, 22 workers, one binary, paired position-balanced rounds,
# exact paired permutation, per-cell dedicated A/Bs (never a corpus sweep).
# 24 of 82 corpus cells reach this seam; all 24 were adjudicated individually:
#
#   arm            q21             corpus verdicts (24 dedicated A/Bs)
#   ------------   -------------   -----------------------------------------
#   TIER (4096)    -41.06 ms       21 WIN, 3 null, 0 REGRESSION   <- SHIPPED
#   flat 8192      -49.84 ms       (q21 only)
#   flat 16384     -53.25 ms       18 WIN, 5 null, 1 REGRESSION
#   flat 32768     -52.41 ms       (q21 only; loses to 16384, p = 0.034)
#
# ⛔ 16,384 IS FASTER ON q21 BY ~12 ms AND IS NOT WHAT SHIPPED, DELIBERATELY.
# It regresses `tpch/q12_shipping_modes` (+3.88%, 1 of 9 rounds, p = 0.0156),
# and that regression has a MECHANISM rather than being noise: q12's probe is
# small, so a 16,384-row grain yields **2 morsels for a 22-worker pool**. Below
# `k = morsels/W = 1` every morsel is on the critical path and the wave wall is
# the max of M draws with no work-stealing slack — the same regime ``
# identified as the source of q21's unexplained 6.61% bimodality. Buying those
# 12 ms properly needs a WAVE-AWARE grain (the `parallel_fork_grain` shape,
# which snaps to a multiple of the pool), not a larger constant. That is the
# next rung and it needs its own pre-registered measurement.
#
# ⚠: `tpch/q18` JOINED q12 IN THAT REGIME, and this seam is where it
# arrives. When the morsel budget moved from L1d to the L2-per-worker share
# (see this file's second module section), q18's second probe — 150,000 rows on
# a 1-column i64 schema — went from the 4096 MIN clamp (37 morsels, k = 1.85)
# to 16384 (10 morsels, k = 0.50), and a slow ~74 ms mode appeared in ~30% of
# its reps with the median unmoved. `forced_rows=4096` removes
# the mode entirely, which is what identifies this seam as the cause; it is a
# DIAGNOSTIC and not a fix, because the same pin gives back a third of the
# corpus win on other cells. Two cells now sit in the k < 1 regime, which is
# the case for the wave-aware grain, not against it.
#
# ⛔ AND DO NOT LAND A POINT HERE FROM ARITHMETIC. `` measured a 7.6%
# grain step worth 35 ms on c5 IN THE COUNTER-INTUITIVE DIRECTION. 8192 vs 16384
# measured -2.44 ms at p = 0.192 — i.e. INDISTINGUISHABLE — so the plateau is
# broad and its edges are where the cost is. Sweep; do not reason.
#
#   forced_rows = 1       -> the JOIN_PROBE tier, stated (== shipped)
#   forced_rows = N >= 2  -> a FLAT grain of N rows (sweeps only)
#   tier_enabled = False  -> the pre DEFAULT tier
#
# ⚠ THE `= 1` ARM DELIBERATELY KEPT ITS MEANING ACROSS THE LANDING. Before it,
# `unset` was the incumbent and `1` was the tier; after it, `unset` IS the tier.
# Had `1` been repurposed, the sweep invocation recorded in this campaign's
# results would silently measure a different arm when re-run. The A/B ORACLE
# moved to its own gate (`tier_enabled=False`) rather than being encoded
# as another integer here, because a kill switch and a sweep parameter are two
# jobs and one integer cannot carry both without a reader having to remember
# which era they are in.
def join_probe_morsel_rows_swept(
    imm policy: MorselSizingPolicy,
    imm schema: Schema,
    forced_rows: Int = 0,
    tier_enabled: Bool = True,
) -> Int:
    """The in-mem join probe's morsel target: the JOIN_PROBE tier.

    `tier_enabled=False` returns the pre `default_morsel_rows` (the A/B oracle);
    `forced_rows=N>=2` forces a flat grain of N rows (measurement only). See this
    seam's header for the measured curve.
    """
    var forced = forced_rows
    if forced == 1:
        return policy.join_probe_morsel_rows(schema)
    if forced > 1:
        return forced
    if not tier_enabled:
        return policy.default_morsel_rows(schema)
    return policy.join_probe_morsel_rows(schema)



# =============================================================================
# Lowering: the morsel size a host records in a segment
# =============================================================================
#
# `segment_morsel_tier` reads the tier off the segment's shape, and
# `lower_segment_morsel_rows` evaluates the policy of `host` for it. Both are
# pure: equal (host profile, segment, schema) give an equal answer, which is
# what lets the physical plan record the value (`record_segment_morsel_rows`)
# instead of each operator re-deriving it.
#
# Tier rule, first match wins:
#   1. a JOIN_PROBE operator or a JOIN_PROBE sink -> JOIN_PROBE
#   2. an AGG sink                                -> AGG
#   3. a Parquet source with no FILTER or JOIN_PROBE operator into a COLLECT
#      sink (a scan that only reads and collects)  -> BULK_SCAN
#   4. anything else                               -> DEFAULT


def segment_morsel_tier(segment: SegmentDescPod) -> UInt8:
    """The morsel tier of `segment`, by the rule above."""
    var has_filter = False
    var has_probe = segment.sink_kind == SINK_JOIN_PROBE
    for i in range(len(segment.ops)):
        var tag = segment.ops[i].tag
        if tag == OP_JOIN_PROBE:
            has_probe = True
        elif tag == OP_FILTER:
            has_filter = True
    if has_probe:
        return MORSEL_TIER_JOIN_PROBE
    if segment.sink_kind == SINK_AGG:
        return MORSEL_TIER_AGG
    if (
        segment.source_kind == SOURCE_PARQUET
        and segment.sink_kind == SINK_COLLECT
        and not has_filter
    ):
        return MORSEL_TIER_BULK_SCAN
    return MORSEL_TIER_DEFAULT


def lower_segment_morsel_rows(
    host: HostProfile, segment: SegmentDescPod, schema: Schema
) -> Int:
    """Rows per morsel for `segment` on `host`.

    `schema` is the schema that flows through the segment (after projection).
    """
    var policy = MorselSizingPolicy.for_host(host)
    return policy.morsel_rows(schema, segment_morsel_tier(segment))


def record_segment_morsel_rows(
    host: HostProfile, mut segment: SegmentDescPod, schema: Schema
):
    """Lowering step: write the host's morsel size into `segment.morsel_rows`."""
    segment.morsel_rows = lower_segment_morsel_rows(host, segment, schema)
