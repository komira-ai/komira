# =============================================================================
# komira_shuffle/retention.mojo
#   PER-EPOCH RETENTION / GC — the cross-epoch whole-epoch reaper that bounds an
#   UNBOUNDED multi-segment continuous stream's shuffle storage.
# =============================================================================
#
# Per-epoch retention/GC over the per-epoch `{shuffle_id}/{step_id}/` object
# families; the floor is tied to the consumer's CHECKPOINTED cursor, NEVER
# wall-clock.
#
# -----------------------------------------------------------------------------
# WHY THIS EXISTS
# -----------------------------------------------------------------------------
# The continuous shuffle INSTANCES the proven one-shot seal once per EPOCH
# (epoch == step_id): segment N mints `{shuffle_id}/{e}/` object families
# (`{producer}.seg` bodies + the `_entries` CAS manifest + the `_seal` CAS
# manifest) for e = 0, 1, 2, ... FOREVER while segment N+1 consumes earlier
# epochs. With NO reclamation an unbounded stream accumulates those families
# without bound — the multi-segment MVP only ran over a BOUNDED source precisely
# because this reaper did not exist yet. This module adds it.
#
# -----------------------------------------------------------------------------
# THE FLOOR SEMANTICS (the load-bearing fail-SAFE property)
# -----------------------------------------------------------------------------
# The RECLAIM FLOOR is the MINIMUM checkpointed consumer cursor across ALL
# reducers/consumers — the SLOWEST consumer's durable position. The cursor (an
# `EpochCursor`, the streaming shuffle source) is "the next epoch to poll": a
# consumer at cursor `c` has READ-AND-CHECKPOINTED through epoch `c-1` and STILL
# NEEDS epoch `c` onward. So:
#
#   reclaim_floor = min(consumer_cursors)
#   an epoch e is RECLAIMABLE  <=>  e < reclaim_floor   (STRICTLY below)
#
# An epoch AT the floor is STILL NEEDED by the slowest consumer (its cursor
# points AT it) — reaping it is silent data loss. This is why the predicate is
# `e < floor`, NEVER `e <= floor`. The whole design is FAIL-SAFE: when in doubt,
# RETAIN. A too-low floor merely wastes storage (a leak, recoverable); a too-high
# floor is silent data loss for a lagging consumer (FORBIDDEN). The floor is tied
# to the durable CONSUMER cursor and is NEVER wall-clock and NEVER the producer's
# position — a fast producer (or wall-clock) must not be able to reclaim under a
# consumer that has not yet read.
#
# -----------------------------------------------------------------------------
# WHAT IT DELETES (whole-epoch reclamation)
# -----------------------------------------------------------------------------
# For each reclaimable epoch `e`, the reaper deletes the WHOLE per-epoch family:
#   * each producer's `{shuffle_id}/{e}/{producer}.seg` body (the producer set is
#     the seal's `committed_producers` — read from the durable `_seal`);
#   * the `_entries` CAS manifest's entire key family (chunks + `_HEAD` +
#     `_LOG_START` + tombstones + dedup sentinels) via `CasManifestStore.
#     purge_all` (the manifest reclaims its OWN keys — key-layout encapsulation);
#   * the `_seal` CAS manifest's entire key family via the same `purge_all`.
# `FileSystem.delete` (the `ConditionalWriteStore.delete` verb) is idempotent
# (delete-of-absent succeeds), so a re-run of the reaper over an already-reaped
# epoch is a no-op — on LocalFs and on S3.
#
# -----------------------------------------------------------------------------
# WITHIN-EPOCH `_scan_entries` log_start NOTE
# -----------------------------------------------------------------------------
# Within a SINGLE epoch the `_entries` scan stays bounded (`_scan_entries` walks
# `[0, head]` of that epoch's OWN per-step manifest, and a sealed epoch's head is
# fixed). This reaper reclaims WHOLE epochs (the cross-epoch dimension); it does
# NOT mutate a still-live epoch's `_entries`, so the `log_start == 0`
# assumption at seal_driver._scan_entries is NOT violated by whole-epoch
# reclamation — a reaped epoch is GONE (its scan never runs again), and a live
# epoch's log_start is still 0. The within-epoch log_start seeding the
# seal_driver comment flags is for a future PARTIAL within-epoch trim
# (truncating a single still-live epoch's `_entries` tail), which this
# whole-epoch reaper does not do.
#
# -----------------------------------------------------------------------------
# Encapsulation discipline
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any signature (whole surface is value / Int64 / List
#     / by-value store handle).
#   * ZERO wildcard origins / `unsafe_from_address` / `take_pointee`.
# * The store is held BY VALUE (clone-shared substrate). heap-reuse N/A
#     (transient values + by-value store handle, no byte-slab element, no
#     wildcard-origin field).
#   * The reaper does NOT reconstruct CAS-internal key names — it deletes the
#     PUBLIC shuffle `.seg` keys (`shuffle_segment_key`) + calls the manifest's
#     own `purge_all`. The `_entries` / `_seal` key INTERNALS stay private to
#     `cas_manifest` (matching the SOLE-READ-BARRIER discipline: this module
#     constructs the two manifests over CLONED handles, same as the seal driver).
# =============================================================================

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
)
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.path import Path
from komira_shuffle.seal import StepComplete
from komira_shuffle.seal_driver import (
    entries_prefix,
    seal_prefix,
    read_seal,
)
from komira_shuffle.sink import shuffle_segment_key


# -----------------------------------------------------------------------------
# reclaim_floor — the MIN-across-consumers floor (the slowest consumer's cursor).
# -----------------------------------------------------------------------------


def reclaim_floor(consumer_cursors: List[Int64]) raises -> Int64:
    """Compute the RECLAIM FLOOR = the MINIMUM checkpointed consumer cursor
    across ALL reducers/consumers (the slowest consumer's durable position).

    Each cursor is an `EpochCursor.epoch`: "the next epoch to poll" — a consumer
    at cursor `c` has read-and-checkpointed THROUGH `c-1` and still needs epoch
    `c` onward. The min over all consumers is the lowest epoch ANY consumer still
    needs. An epoch `e` is reclaimable iff `e < reclaim_floor` (STRICTLY below) —
    see `reap_epochs_below`.

    FAIL-SAFE: an EMPTY consumer set RAISES (it would otherwise yield a vacuous
    floor that could reap everything — refusing to reclaim under a missing
    consumer is the safe direction). A single consumer's cursor IS the floor (no
    other consumer to pin it lower)."""
    if len(consumer_cursors) == 0:
        raise Error(
            "shuffle_retention.reclaim_floor: empty consumer-cursor set — refusing"
            " to compute a floor (a missing consumer must NOT permit reclamation;"
            " fail-safe = retain)."
        )
    var floor = consumer_cursors[0]
    for i in range(1, len(consumer_cursors)):
        if consumer_cursors[i] < floor:
            floor = consumer_cursors[i]
    return floor


# -----------------------------------------------------------------------------
# ShuffleReapStats — what a reap pass did (observability for the governor / test).
# -----------------------------------------------------------------------------


@fieldwise_init
struct ShuffleReapStats(Copyable, Movable, Deinitable):
    """The outcome of one whole-epoch reap pass. POD value type (Int64 scalars);
    never a byte-slab element (heap-reuse N/A).

    Fields:
      var floor: Int64           — the reclaim floor used (min consumer cursor).
      var epochs_reaped: Int64   — how many WHOLE epochs were reclaimed.
      var objects_deleted: Int64 — total DELETE calls issued across all reaped
        epochs (`.seg` bodies + the two manifests' purge_all counts)."""

    var floor: Int64
    var epochs_reaped: Int64
    var objects_deleted: Int64


# -----------------------------------------------------------------------------
# reap_epoch — delete ONE whole epoch's object family (the per-epoch mechanism).
# -----------------------------------------------------------------------------


def reap_epoch[
    S: CloneableConditionalWriteStore
](
    mut store: S,
    shuffle_id: Int64,
    epoch: Int64,
    expected_producers: List[Int64],
    max_park_iters: Int = 4,
) raises -> Int64:
    """Reclaim ONE whole epoch's `{shuffle_id}/{epoch}/` object family. Returns
    the number of DELETE calls issued. UNCONDITIONAL: the CALLER (reap_epochs_
    below) owns the `epoch < floor` policy; this is the per-epoch mechanism.

    The producer set whose `.seg` bodies to delete comes from the epoch's durable
    `_seal` (`committed_producers`) when present; if the seal is absent (an epoch
    that was never sealed — should not happen for a reclaimable epoch, since a
    consumer can only advance past a SEALED epoch) we fall back to
    `expected_producers` so a torn/half-written epoch still gets its `.seg`
    bodies swept. Either way the two manifests' `purge_all` reclaims the
    `_entries` / `_seal` key families regardless.

    Idempotent — re-running over an already-reaped epoch is a no-op (delete-of-
    absent succeeds)."""
    var deletes = Int64(0)

    # Resolve the producer set to sweep `.seg` keys for. Prefer the durable
    # seal's committed set (authoritative for a sealed epoch); on seal-absence
    # fall back to the plan-fixed expected set (defensive sweep of a half-written
    # epoch). A torn-set / corrupt seal raise is NOT swallowed — it propagates
    # (the reaper must not silently leak under a corrupt seal).
    var producers = List[Int64]()
    var seal_present = True
    try:
        var seal: StepComplete = read_seal(
            store, shuffle_id, epoch, expected_producers, max_park_iters
        )
        for i in range(len(seal.committed_producers)):
            producers.append(seal.committed_producers[i])
    except e:
        var msg = String(e)
        if msg.find(String("absent")) >= 0:
            # Seal absent — fall back to the plan-fixed expected set (sweep a
            # never-sealed epoch's `.seg` bodies defensively).
            seal_present = False
            for i in range(len(expected_producers)):
                producers.append(expected_producers[i])
        else:
            # A real error (torn set / corrupt seal) — propagate.
            raise e^
    _ = seal_present

    # Delete each producer's `.seg` body (the PUBLIC shuffle segment key).
    for i in range(len(producers)):
        var seg_key = Path.parse(
            shuffle_segment_key(shuffle_id, epoch, producers[i])
        )
        store.delete(seg_key)
        deletes += Int64(1)

    # Reclaim the `_entries` manifest's WHOLE key family (the manifest reclaims
    # its OWN keys — key-layout encapsulation; the reaper never reconstructs CAS-
    # internal key names). Constructed over a CLONED handle (same as the seal
    # driver), so it shares the same backing.
    var entries_m = CasManifestStore[S](
        store.clone(), entries_prefix(shuffle_id, epoch), RetryPolicy.default()
    )
    deletes += entries_m.purge_all()
    _ = entries_m^

    # Reclaim the `_seal` manifest's WHOLE key family.
    var seal_m = CasManifestStore[S](
        store.clone(), seal_prefix(shuffle_id, epoch), RetryPolicy.default()
    )
    deletes += seal_m.purge_all()
    _ = seal_m^

    return deletes


# -----------------------------------------------------------------------------
# reap_epochs_below — the FLOOR-GATED cross-epoch reaper (the headline verb).
# -----------------------------------------------------------------------------


def reap_epochs_below[
    S: CloneableConditionalWriteStore
](
    mut store: S,
    shuffle_id: Int64,
    floor: Int64,
    lowest_live_epoch: Int64,
    expected_producers: List[Int64],
    max_park_iters: Int = 4,
) raises -> ShuffleReapStats:
    """Reap EVERY epoch strictly BELOW `floor` (the FAIL-SAFE cross-epoch reaper).

    Reaps epochs in `[lowest_live_epoch, floor)` — i.e. `e` such that
    `lowest_live_epoch <= e < floor`. `lowest_live_epoch` is the lowest epoch the
    caller believes may still have durable objects (typically the last reaped
    floor, so successive passes do not re-scan already-reaped epochs); pass 0 on
    the first pass. The STRICT `e < floor` predicate is the load-bearing fail-
    safe line: an epoch AT the floor is still needed by the slowest consumer (its
    cursor points AT it) — reaping it would be silent data loss. NEVER use
    `e <= floor`.

    The `floor` MUST be `reclaim_floor(consumer_cursors)` — the MIN checkpointed
    cursor across ALL consumers. This function does NOT compute the floor (the
    caller threads the durable consumer cursors); it only enforces the strict-
    below predicate and the per-epoch reclamation. Passing a wall-clock or
    producer-derived floor would violate the design (the floor MUST be the
    durable CONSUMER cursor) — that is the caller's invariant.

    Idempotent + safe to re-run (per-epoch reclamation is delete-of-absent
    tolerant). Returns the reap stats (floor used, whole epochs reaped, total
    deletes)."""
    if lowest_live_epoch < Int64(0):
        raise Error(
            "shuffle_retention.reap_epochs_below: negative lowest_live_epoch "
            + String(lowest_live_epoch)
        )
    var epochs_reaped = Int64(0)
    var objects_deleted = Int64(0)
    var e = lowest_live_epoch
    # STRICT-BELOW: reap only e < floor; an epoch AT the floor is RETAINED.
    while e < floor:
        objects_deleted += reap_epoch(
            store, shuffle_id, e, expected_producers, max_park_iters
        )
        epochs_reaped += Int64(1)
        e += Int64(1)
    return ShuffleReapStats(floor, epochs_reaped, objects_deleted)
