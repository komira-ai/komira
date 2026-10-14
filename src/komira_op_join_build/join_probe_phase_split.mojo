# =============================================================================
# join_probe_phase_split -- the SIZE GATE and the FIRE witness for the
# phase-split (batched, memory-level-parallel) inner probe walk.
# =============================================================================
#
# WHAT THE LEVER IS. `HashJoinBuilder._probe_inner_chunk` walks ONE probe row's
# hash chain to exhaustion before touching the next row, so chain entry k+1's
# ADDRESS depends on the line entry k landed in. Every miss is therefore
# serialised against every other miss for that row, and the CPU has nothing else
# outstanding to hide it behind. The phase-split arm batches B probe rows and
# runs the walk in PHASES -- seed all B directory lookups, then gather all live
# rows' chain records, then compare/emit/compact -- so the k-th step of B
# DIFFERENT rows is B independent loads and the memory system sees them all at
# once.
#
# MEASURED, on real Broadwell-EP hardware, BEFORE any of this was written.
# The numbers that matter here:
#   * -44.5% single-threaded, -30.1% at the 20 workers hc4 actually runs at.
#   * The win is PURE LATENCY: LLC-load-misses/row is IDENTICAL (the winning arm
#     takes 1.3% MORE), instructions/row go UP 16-21%, and offcore requests
#     outstanding roughly DOUBLES (3.2 -> 6.2). So this lever BUYS NOTHING when
#     the misses it overlaps do not exist.
#   * The decisive control: batching only the SEED and keeping the row-at-a-time
#     WALK measured +12.83%. The phase-split WALK is the entire win, which is why
#     "just prefetch further" is not an alternative to it.
#
# WHY THIS FILE EXISTS AT ALL -- THE GATE IS NOT AN OPTIMISATION, IT IS THE
# CORRECTNESS OF THE PERFORMANCE CLAIM. +16-21% instructions with zero extra
# bytes has nothing to hide behind when the table is cached (the fused-record
# layout's twin regression was `tpch/q14_promotion_effect` +17.14%), so the
# lever needs a SIZE GATE, not a flag day. A join whose whole index sits in
# L2/L3 has no memory latency to overlap, so the extra instructions are the
# ONLY thing the lever contributes there.
#
# THE GATE IS THEREFORE A CACHE-RESIDENCY TEST, NOT A ROW-COUNT HEURISTIC. It is
# expressed in BYTES OF INDEX because that is the quantity the mechanism is
# about; a row count is a proxy that changes meaning the moment the chain-entry
# layout changes (which it did, twice, shortly before this landed).
#
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, alloc

from komira_join_assembly.join_payload_inline import join_payload_entry_bytes


# -----------------------------------------------------------------------------
# Tuning constants
# -----------------------------------------------------------------------------

# Probe rows per batch.
#
# The falsifier measured batch size FLAT from 128 to 1024 and COLLAPSING at
# >= 2048, where "scratch + the batch's prefetched head lines exceed L1 then L2".
# 256 is chosen inside that flat region rather than at its top because the
# production kernel carries scratch the falsifier did not:
#
#   hot, touched every round : d_key + d_cur + d_slot + g_key + g_next
#                              = 5 * 256 * 8 B  = 10 KiB
#   prefetched chain lines   = 256 * 64 B       = 16 KiB
#                                                 ------
#                                                 26 KiB  < 32 KiB L1d
#
# The match buffer and the counting-sort histogram are NOT in that figure on
# purpose: they are written once and read once per batch (streaming), never in
# the round loop, so they do not compete for the round's L1 residency.
comptime JOIN_PS_BATCH: Int = 256

# Matches buffered per batch before the rounds are cut short.
#
# 4x the batch, i.e. headroom for an average fan-out of 4 build rows per probe
# row. Beyond it the batch STOPS EARLY and emits only the probe rows that
# completed -- see `_probe_inner_chunk_ps`'s `s_stop` truncation, which is a
# correctness path, not a fallback for pathological data only.
comptime JOIN_PS_MATCH_CAP: Int = 1024

# The chunk-capacity headroom a batch requires before it is started.
#
# ⚠ LOAD-BEARING, AND ITS FAILURE MODE IS A SILENTLY TRUNCATED JOIN. The kernel
# returns a SHORT chunk rather than running a row-at-a-time tail when the
# caller's buffer is nearly full, and a chunk of length 0 is the driver's
# "probe exhausted" signal (the join probe operator returns NEED_MORE_INPUT on
# a zero count). So a `chunk_capacity` below this value could make the very
# first call return 0 with rows still unprobed. `join_phase_split_admits`
# REFUSES that case; it is not merely unlikely, it is excluded.
comptime JOIN_PS_MIN_HEADROOM: Int = 4 * JOIN_PS_BATCH

# The size gate: minimum join-index footprint, in bytes, for the phase-split arm.
#
# 32 MiB. The rationale, stated so it can be argued with rather than re-guessed:
#
#   * The lever converts serialised misses into overlapped ones. Below the point
#     where the index stops fitting in last-level cache there are no such misses,
#     and the +16-21% instructions are pure cost.
#   * The fleet's L3 runs 8-45 MiB per socket. A threshold BELOW the largest L3
#     would engage the lever on a join that is cache-resident on the big boxes
#     and pay the instruction tax there for nothing. A threshold at 32 MiB sits
#     at the top of that band.
#   * The gate is deliberately asymmetric. Declining a large join costs the
#     -30% we did not take; admitting a cache-resident one costs a REGRESSION on
#     a cell that was previously fine. The second is worse, so the gate errs
#     toward declining.
#   * What 32 MiB is in rows, on the SHIPPED fused layout: capacity is the next
#     power of two above 1.4 * num_build, so index_bytes ~= 8 * capacity +
#     16 * num_build, and the threshold lands at roughly ONE MILLION build rows.
#     Every h2o join cell (build sides of 100 / 10K / 10K / 100K rows) is
#     therefore firmly on the incumbent row-at-a-time path, and hc4 (25M build
#     rows, ~912 MiB of index) is firmly on the phase-split one.
#
# THIS NUMBER IS A HYPOTHESIS WITH A MEASUREMENT ATTACHED, NOT A CONSTANT OF
# NATURE. It is a setting precisely so the boundary can be driven from BOTH
# sides over ONE fixture -- see `join_phase_split_configure`.
comptime JOIN_PS_MIN_INDEX_BYTES: Int = 32 * 1024 * 1024


# -----------------------------------------------------------------------------
# Runtime configuration -- set ONCE per process from a flag, never per call
# -----------------------------------------------------------------------------
#
# A FLAG, NOT AN ENVIRONMENT VARIABLE. `join_phase_split_configure` sets it once
# per process at startup; nothing in this module reads the environment. The
# gate is consulted on every `probe_inner_chunk` entry (~50,000 per hc4 query),
# so the setting lives in a process-global and every read is one relaxed load.
#
#   0  = not configured (reads as the compiled-in default, ON at
#        `JOIN_PS_MIN_INDEX_BYTES`)
#  -1  = OFF
#  >0  = the minimum index footprint, in bytes


def _init_ps_i64() -> OwnedPointer[AtomicI64]:
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _PS_CFG = _Global["komira_join_phase_split_cfg", _init_ps_i64]
comptime _PS_FIRED = _Global["komira_join_phase_split_fired", _init_ps_i64]
comptime _PS_DECLINED = _Global[
    "komira_join_phase_split_declined", _init_ps_i64
]


def _ps_config() raises -> Int:
    """The gate configuration: -1 when OFF, else the byte threshold."""
    # SAFETY: FFI carve-out -- `_Global.get_or_create_ptr` targets
    # KGEN-runtime static storage (process lifetime); the wildcard origin is the
    # stdlib API's own return type and is confined to this function.
    var cur = Int(_PS_CFG.get_or_create_ptr()[][].load())
    if cur != 0:
        return cur
    return JOIN_PS_MIN_INDEX_BYTES


def join_phase_split_configure(enabled: Bool, min_index_bytes: Int = 0) raises:
    """Set the phase-split gate for this process. DEFAULT ON.

    `enabled=False` turns the arm off; otherwise `min_index_bytes > 0`
    overrides `JOIN_PS_MIN_INDEX_BYTES` and `<= 0` keeps it. Meant to be called
    once at startup, before any join probes.
    """
    var v = -1
    if enabled:
        v = min_index_bytes if min_index_bytes > 0 else JOIN_PS_MIN_INDEX_BYTES
    # SAFETY: FFI carve-out (see `_ps_config`).
    _PS_CFG.get_or_create_ptr()[][].store(Scalar[DType.int64](v))


def join_phase_split_reset_config() raises:
    """Return the gate to its default (ON at `JOIN_PS_MIN_INDEX_BYTES`).

    TEST-ONLY. Production sets it once; a test that drives the size gate from
    both sides moves the threshold between cases in ONE process.
    """
    # SAFETY: FFI carve-out (see `_ps_config`).
    _PS_CFG.get_or_create_ptr()[][].store(Scalar[DType.int64](0))


# -----------------------------------------------------------------------------
# The gate
# -----------------------------------------------------------------------------


def join_phase_split_index_bytes(
    num_build: Int, capacity: Int, fused: Bool, pay_inline: Bool = False
) -> Int:
    """Bytes of hash index one `HashJoinBuilder` occupies.

    This is the quantity the size gate is actually about -- what the probe's
    random accesses land in, and therefore whether they miss.

      * `hash_table`  : `capacity` x 8 B, always present, always randomly
                        accessed (one directory read per probe row).
      * FUSED layout  : `key_next`, `num_build` x 16 B (one interleaved
                        {key, next} record per build row).
      * legacy layout : `build_keys` + `next_chain`, `num_build` x 8 B each --
                        the same 16 B, in two arrays instead of one.

    `build_indices` is EXCLUDED: it is elided entirely under the shipped `nobi`
    layout, and where it is present the chain walk does not read it (only the
    emit does, once per match). Counting it would make the gate's answer depend
    on a layout flag that does not change the walk's miss behaviour.

    ⛔ `pay_inline` IS NOT COSMETIC -- THE 16 WAS A HARD-CODED ENTRY WIDTH.
    Under PAYLOAD-INLINE the entry is 32 bytes, so an index of a given row count
    occupies MORE than this function used to say, and the whole point of the
    quantity is what the probe's random accesses land in. Leaving the literal
    would have made the phase-split gate under-report a payload-inline index by
    `16 * num_build` -- 400 MB on hc4 -- and the gate is a cache-residency test
    stated in bytes precisely so that a layout change moves it. The default
    keeps every existing caller on the shipped arithmetic exactly.
    """
    return capacity * 8 + num_build * join_payload_entry_bytes(pay_inline)


def join_phase_split_admits(
    num_build: Int,
    capacity: Int,
    fused: Bool,
    probe_rows: Int,
    chunk_capacity: Int,
    pay_inline: Bool = False,
) raises -> Bool:
    """Should the chunked inner probe take the PHASE-SPLIT walk?

    Four conditions, and each one is a place the lever is known to be worthless
    or unsafe rather than merely unhelpful:

      1. NOT SWITCHED OFF (`join_phase_split_configure(False)`).
      2. INDEX EXCEEDS THE CACHE THRESHOLD. The mechanism is overlapping DRAM
         misses; below this there are none to overlap and the arm's extra
         instructions are pure cost.
      3. THE PROBE IS BIGGER THAN ONE BATCH. A morsel shorter than `B` rows
         cannot fill a batch, so it pays the batch's setup for a fraction of its
         parallelism.
      4. THE CALLER'S CHUNK BUFFER IS AT LEAST `JOIN_PS_MIN_HEADROOM`. Not a
         tuning condition -- see that constant. Below it the kernel could return
         a zero-length chunk with rows still unprobed, which the driver reads as
         "done".

    An EMPTY build side (`capacity == 0`) is excluded by (2) for free.
    """
    var cfg = _ps_config()
    if cfg < 0:
        return False
    if (
        join_phase_split_index_bytes(num_build, capacity, fused, pay_inline)
        < cfg
    ):
        return False
    if probe_rows < JOIN_PS_BATCH:
        return False
    if chunk_capacity < JOIN_PS_MIN_HEADROOM:
        return False
    return True


# -----------------------------------------------------------------------------
# FIRE witness
# -----------------------------------------------------------------------------
#
# SAME REASON `join_layout_counter` EXISTS, AND THE SAME FAILURE IT PREVENTS.
# This lever is ANSWER-PRESERVING by construction, so a value oracle is blind to
# whether it ran: both arms produce identical bytes whether or not the new arm
# was ever entered. A test that asserts "the size gate keeps
# small joins on the incumbent path" is EXACTLY that shape -- its passing
# condition on the small side is that nothing happened -- so it needs a witness
# for both dispositions, not just one.
#
# ⚠ LATCHED, for the same reason the layout counter's hot recorder is: this is
# read once per `probe_inner_chunk` entry, ~50,000 times per hc4 query across 20
# workers. An unconditional `fetch_add` there is ~50,000 contended atomic
# read-modify-writes on one line, inside the treatment arm, biasing the
# measurement in the direction that makes the lever look worse. The latch costs
# one relaxed load of a clean line and a predicted branch.
#
# ⚠ THE CONSEQUENCE, STATED: these count DISPOSITIONS OBSERVED, not calls. Each
# is 0 or 1 per process per reset. A test asserting a call count would be
# asserting the latch, not the lever.


def join_phase_split_record(admitted: Bool) raises:
    """Latch that a chunked inner probe resolved the gate one way or the other.
    """
    # SAFETY: FFI carve-out (see `_ps_config`).
    if admitted:
        var gp = _PS_FIRED.get_or_create_ptr()
        if Int(gp[][].load()) == 0:
            gp[][].store(Scalar[DType.int64](1))
    else:
        var gp2 = _PS_DECLINED.get_or_create_ptr()
        if Int(gp2[][].load()) == 0:
            gp2[][].store(Scalar[DType.int64](1))


def join_phase_split_fired() raises -> Bool:
    """Did any chunked inner probe take the phase-split walk this process?"""
    # SAFETY: FFI carve-out (see `_ps_config`).
    return Int(_PS_FIRED.get_or_create_ptr()[][].load()) != 0


def join_phase_split_declined() raises -> Bool:
    """Did any chunked inner probe take the incumbent row-at-a-time walk?"""
    # SAFETY: FFI carve-out (see `_ps_config`).
    return Int(_PS_DECLINED.get_or_create_ptr()[][].load()) != 0


def reset_join_phase_split_counters() raises:
    """Clear both latches (test setup)."""
    # SAFETY: FFI carve-out (see `_ps_config`).
    _PS_FIRED.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _PS_DECLINED.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
