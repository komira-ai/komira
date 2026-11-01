# =============================================================================
# rg_prune_counter — process-global counters of the row-group statistics prune
# =============================================================================
#
# A scan with a pushed predicate evaluates it against each row group's footer
# min/max once, when the source is built, and claims only the survivors; the
# per-claim statistics prune at the decode site then has nothing left to
# prove and is skipped. A pruned row group holds no matching row, so a scan
# that prunes and one that does not return the same rows: these counters are
# what a test reads instead.
#
#   * `rg_prune_setup_evals`: sources that ran the setup evaluation.
#   * `rg_prune_setup_pruned`: row groups the setup removed from the claim
#     range (summed over sources).
#   * `rg_prune_perclaim_evals`: row groups the per-claim prune evaluated;
#     0 on a scan whose setup ran.
#   * `rg_prune_bloom_pruned`: row groups the bloom filters removed.
#
# Mechanism: a name-keyed, init-once process-global `_Global` atomic per
# counter. They move once per source, or once per claimed row group, never
# per row.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, alloc


def _init_rg_prune_counter() -> OwnedPointer[AtomicI64]:
    """`_Global` init function: one zeroed counter per process."""
    var raw = alloc[AtomicI64](1)
    # SAFETY: `raw` is the one fresh allocation above; the scalar is written
    # in place before `OwnedPointer` takes ownership, and `raw` never leaves
    # this function. The write relies on `AtomicI64` holding exactly one
    # int64 at offset 0 (the same layout as `Scalar[DType.int64]`), which its
    # one-field definition in `komira_atomic_alias` fixes.
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _RG_PRUNE_SETUP_EVALS = _Global["komira_parquet_rg_prune_setup_evals", _init_rg_prune_counter]
comptime _RG_PRUNE_SETUP_PRUNED = _Global["komira_parquet_rg_prune_setup_pruned", _init_rg_prune_counter]
comptime _RG_PRUNE_PERCLAIM_EVALS = _Global["komira_parquet_rg_prune_perclaim_evals", _init_rg_prune_counter]
comptime _RG_PRUNE_BLOOM_PRUNED = _Global["komira_parquet_rg_prune_bloom_pruned", _init_rg_prune_counter]


@always_inline
def rg_prune_setup_record(pruned: Int) raises:
    """Record one setup evaluation that removed `pruned` row groups."""
    _ = _RG_PRUNE_SETUP_EVALS.get_or_create_ptr()[][].fetch_add(Int64(1))
    _ = _RG_PRUNE_SETUP_PRUNED.get_or_create_ptr()[][].fetch_add(Int64(pruned))


@always_inline
def rg_prune_perclaim_incr() raises:
    """Record one per-claim statistics-prune evaluation."""
    _ = _RG_PRUNE_PERCLAIM_EVALS.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def rg_prune_bloom_record(pruned: Int) raises:
    """Record `pruned` row groups removed by the bloom filters."""
    _ = _RG_PRUNE_BLOOM_PRUNED.get_or_create_ptr()[][].fetch_add(Int64(pruned))


def rg_prune_bloom_pruned() raises -> Int:
    """Row groups the bloom filters removed, process-wide."""
    return Int(_RG_PRUNE_BLOOM_PRUNED.get_or_create_ptr()[][].load())


def rg_prune_setup_evals() raises -> Int:
    """Sources that ran the setup evaluation, process-wide."""
    return Int(_RG_PRUNE_SETUP_EVALS.get_or_create_ptr()[][].load())


def rg_prune_setup_pruned() raises -> Int:
    """Row groups the setup removed from claim ranges, process-wide."""
    return Int(_RG_PRUNE_SETUP_PRUNED.get_or_create_ptr()[][].load())


def rg_prune_perclaim_evals() raises -> Int:
    """Per-claim statistics-prune evaluations, process-wide."""
    return Int(_RG_PRUNE_PERCLAIM_EVALS.get_or_create_ptr()[][].load())


def reset_rg_prune_counters() raises:
    """Zero the four counters (a test's setup)."""
    _RG_PRUNE_SETUP_EVALS.get_or_create_ptr()[][].store(Int64(0))
    _RG_PRUNE_SETUP_PRUNED.get_or_create_ptr()[][].store(Int64(0))
    _RG_PRUNE_PERCLAIM_EVALS.get_or_create_ptr()[][].store(Int64(0))
    _RG_PRUNE_BLOOM_PRUNED.get_or_create_ptr()[][].store(Int64(0))
