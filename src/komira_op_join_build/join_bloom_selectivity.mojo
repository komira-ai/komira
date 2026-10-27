# =============================================================================
# join_bloom_selectivity -- BLOOMSEL: the composite probe's bloom pre-check is a
#   FILTER, and a filter that rejects nothing is pure cost. This module holds
#   the setting, the pure latch predicate and the arming witness.
# =============================================================================
#
# WHAT IS BEING GATED. The composite (multi-key) parallel probe runs the bloom
# check on EVERY probe row, unconditionally. The check is a random load into
# the filter plus its address arithmetic (32 of the 38 instructions of the
# probe's first phase per row) and it buys a skipped bucket-head load and chain
# walk ONLY on the rows it REJECTS.
#
# ON `sdk/c5` IT REJECTS NOTHING AT ALL, AND THE REST OF THE CORPUS IS NOT
# CLOSE TO IT. One repetition each, 44 workers, summed:
#
#   cell        probe_rows   bloom_pass          chain_steps   arm
#   sdk/c5       2,000,000   2,000,000 (100.00%)  42,964,547   STRING_BYTES
#   sdk/c5hc    20,000,000  17,560,334 ( 87.80%)  50,368,818   STRING_BYTES
#   tpch/q20       800,000     543,591 ( 67.95%)     825,750   INT64 x2
#   h2o/j5       6,000,000   3,809,968 ( 63.50%)   8,418,691   INT64 x2
#   tpch/q9        800,000      42,624 (  5.33%)     344,769   INT64 x4
#
# THE MECHANISM SAYS THE THRESHOLD CANNOT BE DUCKDB'S. What a REJECTED row
# avoids here is a bucket-head load out of the hash table, which on a rejected
# key almost always reads `_CHAIN_END` and walks nothing. So disarming TRADES
# one random load into a small, hot bloom for one random load into a large,
# cold hash table. That trade wins only where the bloom rejects almost
# NOTHING, and it loses wherever the bloom does real work (`tpch/q9` rejects
# 94.67% of its probe rows).
#
# DuckDB's `BF_THRESHOLD = 0.25` would disarm four of the five cells above, q9
# included: the right constant for a filter whose rejection skips a DECODE, the
# wrong one for a filter whose rejection skips a load of comparable cost.
# `BLOOMSEL_DEFAULT_PASS_PCT` is therefore **100**: disarm only where the
# SAMPLED bloom rejected nothing at all.
#
# "SAMPLED" IS LOAD-BEARING. A prefix is not a random sample. 20 workers,
# window 65,536:
#
#   cell        SAMPLED pass    WHOLE-RUN pass   disarmed at pct=100
#   sdk/c5      100.00%         100.00%          20 of 20   (checks skipped:    689,280)
#   sdk/c5hc    100.00%          87.80%          20 of 20   (checks skipped: 18,689,280)
#   h2o/j5       63.50%          63.50%           0 of 20
#   tpch/q20     67.95%          67.95%           0 of 20
#   tpch/q9       5.33%           5.33%           0 of 20
#
# `sdk/c5hc`'s first 65,536 rows per worker pass 100% while its whole run
# passes 87.80%, so it DISARMS at 100. The latch's reach is decided by the
# PREFIX each worker receives, and on a clustered or sorted probe side the
# prefix and the whole can disagree by any amount. A threshold is therefore not
# a cell filter: the lever for reach is the WINDOW (sample more, or strided).
#
# DUCKDB'S COUNTERPART, WHOSE MECHANISM IS BORROWED EVEN THOUGH ITS CONSTANT IS
# NOT. `SelectivityOptionalFilter` samples its child over the first
# `BF_CHECK_N = 75` vectors and PAUSES it for the rest of the scan once
# observed selectivity reaches `BF_THRESHOLD = 0.25`. The pause is one-way and
# the decision is thread-local state on the scan, not a planner estimate. Both
# properties are kept.
#
# VALUE-INVARIANT, WHICH IS WHY THE WITNESS IS NOT OPTIONAL. A bloom filter has
# no false negatives, so DISARMING it cannot change the answer. Every value
# oracle is satisfied by an arm that never ran, so the counters below are
# notched on BOTH dispositions: `kept=0 disarmed=0` reads as "never reached"
# rather than as "kept".
#
# THE SETTING. `bloomsel_configure(window_rows, pass_pct)` sets it once per
# process, from a flag, before any probe runs; nothing here reads the
# environment. An unconfigured process reads window 0, the lever OFF. The
# witness line prints to STDERR, only under the scheduler trace.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.io import FileDescriptor
from std.memory import alloc, OwnedPointer

from komira_async.runtime.sched_trace import sched_trace_enabled


# fd 2: a query's stdout is its result stream.
comptime _BLS_STDERR: FileDescriptor = FileDescriptor(2)


# =============================================================================
# Constants
# =============================================================================

comptime BLOOMSEL_DEFAULT_PASS_PCT: Int = 100
"""Disarm only when the sampled bloom rejected NOTHING.

⛔ DELIBERATELY NOT DUCKDB'S 25. See the header's measured table: 25 disarms
four of the five composite-join corpus cells, `tpch/q9` included, whose bloom
rejects 94.67% of its probe rows. 100 keeps all three cells whose bloom does real
work and disarms the two whose SAMPLED prefix rejected nothing.

⚠ MEASURED REACH AT 100 IS **TWO** CELLS, NOT ONE — `sdk/c5` AND `sdk/c5hc`.
c5hc's whole-run pass rate is 87.80% but its first 65,536 rows per worker are
100%, and the latch sees only the prefix. Do not restate this threshold as
"only the cell that rejects nothing"; that sentence was in this file and it was
false."""

comptime BLOOMSEL_MAX_PASS_PCT: Int = 100
"""A pass rate above 100% is unreachable, so a knob set past it would disarm on
every cell including one where every row is rejected. Clamped, not honoured."""


# =============================================================================
# The setting -- ONE value is both the arm selector and the sample window
# =============================================================================


def _init_bls_i64() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn: allocate one zeroed counter once per process."""
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _BLS_WINDOW = _Global["komira_join_bloomsel_window", _init_bls_i64]
comptime _BLS_PCT = _Global["komira_join_bloomsel_pct", _init_bls_i64]


def bloomsel_configure(window_rows: Int, pass_pct: Int = 0) raises:
    """Set the latch for this process: the per-worker sample window in PROBE
    ROWS (`<= 0` is OFF, the default) and the disarm pass rate in percent
    (`<= 0` selects `BLOOMSEL_DEFAULT_PASS_PCT`).

    Meant to be called once per process, from a flag, before any probe runs.
    The window is the arm selector too, so `0` against `N` is a
    single-variable comparison inside one process.
    """
    # SAFETY: FFI carve-out -- `_Global.get_or_create_ptr` targets KGEN-runtime
    # static storage (process lifetime); the wildcard origin is the stdlib API's
    # own return type and is confined to this function.
    var w = window_rows if window_rows > 0 else 0
    var p = pass_pct if pass_pct > 0 else 0
    _BLS_WINDOW.get_or_create_ptr()[][].store(Scalar[DType.int64](w))
    _BLS_PCT.get_or_create_ptr()[][].store(Scalar[DType.int64](p))


def bloomsel_reset_config() raises:
    """TEST-ONLY. Return the setting to its default (OFF)."""
    # SAFETY: FFI carve-out (see `bloomsel_configure`).
    _BLS_WINDOW.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _BLS_PCT.get_or_create_ptr()[][].store(Scalar[DType.int64](0))


def bloomsel_window_rows() raises -> Int:
    """Per-worker sample size in PROBE ROWS. `0` (never configured) is OFF."""
    # SAFETY: FFI carve-out (see `bloomsel_configure`).
    return Int(_BLS_WINDOW.get_or_create_ptr()[][].load())


def bloomsel_pass_pct() raises -> Int:
    """Disarm the bloom when the sampled PASS RATE reaches this percent.

    Never configured (or configured `<= 0`) -> `BLOOMSEL_DEFAULT_PASS_PCT`.
    Values above `BLOOMSEL_MAX_PASS_PCT` are clamped. `0` would disarm
    unconditionally and is therefore read as unset: a setting whose zero means
    "always" is the one set by accident when "never" was meant.
    """
    # SAFETY: FFI carve-out (see `bloomsel_configure`).
    var v = Int(_BLS_PCT.get_or_create_ptr()[][].load())
    if v <= 0:
        return BLOOMSEL_DEFAULT_PASS_PCT
    if v > BLOOMSEL_MAX_PASS_PCT:
        return BLOOMSEL_MAX_PASS_PCT
    return v


def bloomsel_trace_enabled() -> Bool:
    """Whether the `[bloomsel]` witness line prints: the scheduler trace.
    SEPARATE from the lever's own setting, so the line prints on the OFF arm
    too -- see the header."""
    return sched_trace_enabled()


# =============================================================================
# The latch predicate — PURE, so it is testable with no join, no fixture and no
# dispatcher
# =============================================================================


@always_inline
def bloomsel_should_disarm(passed: Int, seen: Int, pass_pct: Int) -> Bool:
    """True iff the sampled pass rate has reached `pass_pct` percent.

    `passed * 100 >= pass_pct * seen`, in integers — no float, so the verdict is
    exactly reproducible and there is no rounding edge to argue about.

    ⚠ `seen == 0` RETURNS FALSE, and that direction is deliberate. A worker that
    was handed no rows has observed nothing; disarming on no evidence would make
    the lever's behaviour depend on how the morsel counter happened to split, and
    a zero-row worker would then disarm a bloom the OTHER workers are keeping.
    Fail towards the incumbent.

    Args:
        passed: probe rows the bloom ADMITTED during the sample.
        seen: probe rows the bloom was ASKED about during the sample.
        pass_pct: the disarm threshold, as an integer percent.

    Returns:
        True to stop calling the bloom for the rest of this worker's rows.
    """
    if seen <= 0:
        return False
    return passed * 100 >= pass_pct * seen


# =============================================================================
# ARMING WITNESS — see the header on why a value oracle cannot replace it
# =============================================================================


comptime _BLS_KEPT = _Global["komira_join_bloomsel_kept", _init_bls_i64]
comptime _BLS_DISARMED = _Global["komira_join_bloomsel_disarmed", _init_bls_i64]
comptime _BLS_SAVED = _Global["komira_join_bloomsel_saved", _init_bls_i64]


def bloomsel_note_kept() raises:
    """One WORKER finished its sample and KEPT the bloom."""
    # SAFETY: FFI carve-out (see `bloomsel_configure`).
    var g = _BLS_KEPT.get_or_create_ptr()
    _ = g[][].fetch_add(Int64(1))


def bloomsel_note_disarmed() raises:
    """One WORKER finished its sample and DISARMED the bloom."""
    # SAFETY: FFI carve-out (see `bloomsel_configure`).
    var g = _BLS_DISARMED.get_or_create_ptr()
    _ = g[][].fetch_add(Int64(1))


def bloomsel_note_saved(n: Int) raises:
    """Add `n` bloom checks THIS WORKER did not perform because the latch had
    disarmed the filter.

    ⭐ THIS IS THE ONLY OBSERVABLE THAT SEPARATES "THE LATCH DECIDED" FROM "THE
    LATCH TOOK EFFECT", and without it a mutant that notches `disarmed` and then
    keeps calling the bloom anyway is GREEN on every assertion in the tree: the
    disposition counter moves, and the answer is value-invariant either way.

    ⚠ ONE ATOMIC PER WORKER, NEVER PER ROW. The per-row half is a local `+= 1`
    in the `else` of `if bl_active:` — a branch that ALREADY EXISTS and that the
    OFF arm never takes, so the OFF arm pays exactly nothing for this counter.
    """
    if n <= 0:
        return
    # SAFETY: FFI carve-out (see `bloomsel_configure`).
    var g = _BLS_SAVED.get_or_create_ptr()
    _ = g[][].fetch_add(Int64(n))


def bloomsel_saved_checks() raises -> Int:
    """Bloom checks skipped because the latch disarmed. `0` with
    `disarmed > 0` means the latch decided and did not take effect."""
    # SAFETY: FFI carve-out (see `bloomsel_configure`).
    return Int(_BLS_SAVED.get_or_create_ptr()[][].load())


def bloomsel_kept_count() raises -> Int:
    """Workers that reached the latch and kept the bloom."""
    # SAFETY: FFI carve-out (see `bloomsel_configure`).
    return Int(_BLS_KEPT.get_or_create_ptr()[][].load())


def bloomsel_disarmed_count() raises -> Int:
    """Workers that reached the latch and disarmed the bloom."""
    # SAFETY: FFI carve-out (see `bloomsel_configure`).
    return Int(_BLS_DISARMED.get_or_create_ptr()[][].load())


def reset_bloomsel_counters() raises:
    """TEST-ONLY. All THREE counters, together — resetting one would let a test
    read a triple that never coexisted."""
    # SAFETY: FFI carve-out (see `bloomsel_configure`).
    _BLS_KEPT.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _BLS_DISARMED.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _BLS_SAVED.get_or_create_ptr()[][].store(Scalar[DType.int64](0))


def bloomsel_witness(
    wid: Int, window: Int, pass_pct: Int, seen: Int, passed: Int,
    disarmed: Bool, saved: Int,
) -> None:
    """Print the `[bloomsel]` witness for ONE worker's latch decision.

    ⚠ `sep=""` IS LOAD-BEARING. Mojo's `print` separates with a SPACE by
    default, so `print("seen=", n)` emits `seen= 1234` and an operator's
    `grep 'seen=1234'` matches NOTHING — an absent match on a witness reads as
    "the branch never fired".
    """
    print(
        "[bloomsel] wid=", wid,
        " window=", window,
        " pct=", pass_pct,
        " seen=", seen,
        " passed=", passed,
        " disarmed=", 1 if disarmed else 0,
        " saved=", saved,
        sep="",
        file=_BLS_STDERR,
    )
