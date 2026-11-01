# =============================================================================
# join_bloom_l1_resident -- BLOOML1: a bloom filter is a CACHE-MISS AVOIDANCE
#   device. When the structure it guards cannot miss, it has nothing to avoid
#   and is pure cost. This module holds the setting, the pure predicate and the
#   arming witness.
# =============================================================================
#
# THE CELL. `h2o/j1_join_small` joins a 6,000,000-row probe side against a
# **100-row** build side on one INT64 key, and every probe row matches. So the
# bloom is consulted 6,000,000 times and rejects **0**.
#
# THE REJECTION RATE IS NOT THE POINT -- THE GUARDED STRUCTURE'S SIZE IS.
# From the `HashJoinBuilder.build` arithmetic at n = 100:
#
#     min_cap = max(int(100 * 1.4) + 1, 16) = 141   ->  cap = 256
#     hash_table  = cap * 8                          =  2,048 B
#     key_next    = JOIN_KN_WORDS * n * 8 = 2*100*8  =  1,600 B
#     ------------------------------------------------------------
#     index total                                    =  3,648 B
#
# and the bloom itself (`with_ndv_fpp(100, 0.01)`) rounds to 128 B. Against a
# 32,768 B L1d the whole index is 9x inside L1.
#
# =============================================================================
# THE MECHANISM, WHICH IS WHY THIS PREDICATE IS A SIZE AND NOT A SELECTIVITY
# =============================================================================
#
# What a REJECTED probe row avoids is one bucket-head load out of
# `hash_table`, plus whatever chain walk follows it. What EVERY probe row pays
# for the bloom is one load into the filter's 32-byte block plus the
# block-index multiply-shift and the 8-lane block check. So the bloom wins iff
#
#     cost(bloom load) + cost(block check)  <  reject_rate * cost(HT load + walk)
#
# * HT in L3/DRAM, bloom in L1: the right-hand side is 40-200 cycles per
#   rejected row and the bloom wins at modest reject rates. This is what the
#   device is FOR.
# * HT in L2 (~14 cyc), bloom in L1 (~4 cyc): a genuine trade, decided by the
#   reject rate. That regime is `join_bloom_selectivity`'s question.
# * HT in L1: both loads are L1 hits, so the left-hand side is one L1 load
#   PLUS the block check, and the right-hand side is at most one L1 load. The
#   inequality cannot hold for any reject rate in [0, 1].
#
# => THE BOUNDARY IS L1 RESIDENCY OF THE INDEX, AND IT IS DECIDABLE AT BUILD
#    TIME FROM `n` AND `cap`: no sampling, no prefix, no prediction.
#
# THE BUDGET. `BLOOM_L1_DEFAULT_BUDGET_BYTES` is half of a 32 KiB L1d: the
# probe key column streams through L1, the two output vectors stream out of
# it, and the bloom's own blocks sit in it, so half is reserved for them. The
# halving is an engineering reserve, not a measured constant, which is why the
# budget is a setting and the shipped default is OFF. Under the shipped
# fused/nobi layout (`index_bytes = cap*8 + 2*n*8`) the power-of-two cap
# quantises the boundary onto exact row counts:
#
#     budget 16,384 B  ->  declines n <= 512    (n=512: 16,384; n=513: 16,400)
#     budget 32,768 B  ->  declines n <= 1,024  (n=1024: 32,768; n=1025: 32,784)
#
# A THRESHOLD OF THE SAME SHAPE ALREADY EXISTS AND IS LOOSER. `probe_semi` and
# `probe_semi_count` (`join_probe_semi_anti`) carry a `build_n <= 4096` arm
# that bypasses BOTH the bloom AND the prefetch, on the rationale "4096 entries
# * ~24 bytes/entry = ~96KB < L1 cache". Under the shipped fused layout the
# real figure is `8,192*8 + 2*4,096*8` = 131,072 B, four times a 32 KiB L1d.
# That arm is not changed here: it is a different lever (prefetch, not bloom)
# and narrowing it is a measurement, not a tidy-up.
#
# VALUE-INVARIANT, WHICH IS WHY THE WITNESS IS NOT OPTIONAL. A bloom filter
# has no false negatives, so DECLINING one cannot change the answer: a row it
# would have rejected instead loads a bucket head and either finds
# `_CHAIN_END` or walks a chain whose compares all fail. Both arms emit the
# same pairs in the same order, so every value oracle is satisfied by an arm
# that never ran. The counters below are notched on BOTH dispositions, so
# `kept=0 declined=0` reads as "never reached" rather than as "kept".
#
# The decision is taken inside `HashJoinBuilder.build`, the single constructor
# every single-key driver reaches, so the witness prints on every route by
# construction. It prints to STDERR and only under the scheduler trace
# (`sched_trace_enabled`): a query's stdout is its result stream.
#
# THE SETTING. `bloom_l1_configure(budget_bytes)` sets the budget once per
# process, from a flag, before any join builds; nothing here reads the
# environment. An unconfigured process reads 0, the lever OFF.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.io import FileDescriptor
from std.memory import alloc, OwnedPointer

from komira_async.runtime.sched_trace import sched_trace_enabled


# fd 2: a query's stdout is its result stream.
comptime _BL1_STDERR: FileDescriptor = FileDescriptor(2)


# =============================================================================
# Constants
# =============================================================================

comptime BLOOM_L1_L1D_BYTES: Int = 32_768
"""A 32 KiB L1 data cache per core: the smallest L1d of the hosts this engine
is measured on (128 KiB parts exist), so a budget argued against it is
conservative everywhere else."""

comptime BLOOM_L1_DEFAULT_BUDGET_BYTES: Int = 16_384
"""Half of `BLOOM_L1_L1D_BYTES`, the other half reserved for everything ELSE in
L1 while the probe runs.

The halving is an engineering reserve, not a measured constant. Under the
shipped fused/nobi layout this admits **n <= 512** build rows;
`BLOOM_L1_L1D_BYTES` would admit **n <= 1,024**. `h2o/j1_join_small` is 100
rows / 3,648 B and is inside both by more than 4x."""


# =============================================================================
# The setting -- ONE value, arm selector and budget both
# =============================================================================


def _init_bl1_i64() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn: allocate one zeroed counter once per process."""
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _BL1_CFG = _Global["komira_join_bloom_l1_cfg", _init_bl1_i64]
comptime _BL1_KEPT = _Global["komira_join_bloom_l1_kept", _init_bl1_i64]
comptime _BL1_DECLINED = _Global["komira_join_bloom_l1_declined", _init_bl1_i64]
comptime _BL1_ROWS = _Global["komira_join_bloom_l1_rows", _init_bl1_i64]


def bloom_l1_configure(budget_bytes: Int) raises:
    """Set the index-byte budget under which a build DECLINES its bloom.

    Meant to be called once per process, from a flag, before any join builds.
    `budget_bytes <= 0` is OFF (the default), so the OFF arm is spelled
    explicitly rather than by absence and `0` against `16384` is a
    single-variable comparison inside one process.
    """
    # SAFETY: FFI carve-out -- `_Global.get_or_create_ptr` targets KGEN-runtime
    # static storage (process lifetime); the wildcard origin is the stdlib API's
    # own return type and is confined to this function.
    var v = budget_bytes if budget_bytes > 0 else 0
    _BL1_CFG.get_or_create_ptr()[][].store(Scalar[DType.int64](v))


def bloom_l1_budget_bytes() raises -> Int:
    """The index-byte budget under which the bloom is DECLINED. `0` is OFF.

    Contract:
        never configured, or configured <= 0  -> 0, the lever is OFF
        configured n > 0                      -> decline when index bytes <= n
    """
    # SAFETY: FFI carve-out (see `bloom_l1_configure`).
    return Int(_BL1_CFG.get_or_create_ptr()[][].load())


def bloom_l1_trace_enabled() -> Bool:
    """Whether the `[bloom-l1]` witness line prints: the scheduler trace.

    SEPARATE from the lever's own setting, so the line prints on the OFF arm
    too: a witness that exists only when the lever is armed cannot distinguish
    "kept" from "never reached".
    """
    return sched_trace_enabled()


# =============================================================================
# The predicate -- PURE, so it is testable with no join, no fixture and no
# dispatcher
# =============================================================================


@always_inline
def bloom_l1_index_bytes(
    num_build: Int, capacity: Int, kn_words: Int, fused: Bool, nobi: Bool
) -> Int:
    """Bytes of the join index a PROBE can randomly address.

    It counts the arrays the probe touches, not the allocation. Under the
    shipped layout (`fused=True`, `nobi=True`) `build_keys`, `next_chain` and
    `build_indices` are never allocated, so counting them would inflate the
    figure by 24 bytes a row and refuse a decline the geometry allows. Under
    the other layouts (still reachable: they are the differential oracle)
    those three ARE the index and `key_next` is empty.

    `build_indices` is included when present even though the INNER probe reads
    it only on a match: over-counting shrinks the set of declines, which is the
    safe direction.

    Args:
        num_build: Build-side row count.
        capacity: Hash-table bucket count (a power of two, >= 16).
        kn_words: Words per fused chain entry: 2 shipped, 4 payload-inline.
        fused: The interleaved `key_next` layout is in use.
        nobi: `build_indices` is elided.

    Returns:
        Bytes of probe-addressable index.
    """
    # `hash_table` is `List[Int]`: 8 bytes per bucket on every target here.
    var total = capacity * 8
    if fused:
        total += kn_words * num_build * 8
    else:
        # `build_keys: List[Int64]` + `next_chain: List[Int]`.
        total += num_build * 8 + num_build * 8
    if not nobi:
        total += num_build * 8
    return total


@always_inline
def bloom_l1_should_decline(index_bytes: Int, budget_bytes: Int) -> Bool:
    """True iff the guarded index is small enough that the bloom cannot pay.

    `budget_bytes <= 0` is the OFF arm and returns False. A negative budget is
    read as OFF deliberately: the one thing a setting must not be able to spell
    by typo is "decline every bloom".

    Args:
        index_bytes: From `bloom_l1_index_bytes`.
        budget_bytes: From `bloom_l1_budget_bytes`, or a test's own value.

    Returns:
        True to build the index with no bloom and `uses_bloom() == False`.
    """
    if budget_bytes <= 0:
        return False
    return index_bytes <= budget_bytes


# =============================================================================
# ARMING WITNESS -- see the header on why a value oracle cannot replace it
# =============================================================================


def bloom_l1_note_kept() raises:
    """One BUILD reached the predicate and KEPT the bloom."""
    # SAFETY: FFI carve-out (see `bloom_l1_configure`).
    var g = _BL1_KEPT.get_or_create_ptr()
    _ = g[][].fetch_add(Int64(1))


def bloom_l1_note_declined(num_build: Int) raises:
    """One BUILD reached the predicate and DECLINED the bloom.

    `num_build` separates "the predicate decided" from "it decided on
    something": a mutant that declines only empty builds moves `declined` and
    stays green on every count assertion; the row total shows it decided on
    nothing. The other half of "took effect" is structural:
    `HashJoinBuilder.uses_bloom()` on the returned index.
    """
    # SAFETY: FFI carve-out (see `bloom_l1_configure`).
    var g = _BL1_DECLINED.get_or_create_ptr()
    _ = g[][].fetch_add(Int64(1))
    if num_build > 0:
        var r = _BL1_ROWS.get_or_create_ptr()
        _ = r[][].fetch_add(Int64(num_build))


def bloom_l1_kept_count() raises -> Int:
    """Builds that reached the predicate and kept the bloom."""
    # SAFETY: FFI carve-out (see `bloom_l1_configure`).
    return Int(_BL1_KEPT.get_or_create_ptr()[][].load())


def bloom_l1_declined_count() raises -> Int:
    """Builds that reached the predicate and declined the bloom."""
    # SAFETY: FFI carve-out (see `bloom_l1_configure`).
    return Int(_BL1_DECLINED.get_or_create_ptr()[][].load())


def bloom_l1_declined_rows() raises -> Int:
    """Build rows summed over declined indexes. `0` with `declined > 0` means
    the predicate only ever fired on empty builds."""
    # SAFETY: FFI carve-out (see `bloom_l1_configure`).
    return Int(_BL1_ROWS.get_or_create_ptr()[][].load())


def reset_bloom_l1_counters() raises:
    """TEST-ONLY. All three counters together: resetting one would let a test
    read a triple that never coexisted."""
    # SAFETY: FFI carve-out (see `bloom_l1_configure`).
    _BL1_KEPT.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _BL1_DECLINED.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _BL1_ROWS.get_or_create_ptr()[][].store(Scalar[DType.int64](0))


def bloom_l1_reset_config() raises:
    """TEST-ONLY. Return the setting to its default (OFF). Production sets it
    once; a test that drives the gate from both sides moves it between cases."""
    # SAFETY: FFI carve-out (see `bloom_l1_configure`).
    _BL1_CFG.get_or_create_ptr()[][].store(Scalar[DType.int64](0))


def bloom_l1_witness(
    num_build: Int, index_bytes: Int, budget: Int, declined: Bool
) -> None:
    """Print the `[bloom-l1]` witness for ONE build's decision, to stderr.

    `sep=""` is load-bearing: Mojo's `print` separates with a space by default,
    so `print("declined=", n)` emits `declined= 1` and `grep 'declined=1'`
    matches nothing.
    """
    print(
        "[bloom-l1] rows=", num_build,
        " index_bytes=", index_bytes,
        " budget=", budget,
        " declined=", 1 if declined else 0,
        sep="",
        file=_BL1_STDERR,
    )
