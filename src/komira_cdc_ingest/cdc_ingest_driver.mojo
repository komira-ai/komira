# =============================================================================
# cdc_ingest_driver.mojo — the multi-shard tail -> apply -> commit driver loop.
# =============================================================================
#
# The driver runs the tail -> apply -> commit loop over ALL shards of a
# `MultiShardChangeStreamListener`:
#
#   1. Derive the per-shard resume map from the committed Iceberg snapshot
#      summary (there is no separate checkpoint store).
#   2. List the stream's currently-open shards.
#   3. For each shard: open its iterator (after the derived position, or from the
#      oldest record on cold start), poll one batch, and apply it as ONE atomic
#      Iceberg commit that also stamps the updated per-shard positions into the
#      snapshot summary.
#
# Each shard's position is stamped independently. A commit re-stamps the WHOLE
# known positions map, so the latest snapshot's summary is the complete resume
# map.
#
# `run_ingest_pass` performs ONE poll per shard and returns; the caller runs it in
# a loop (and decides when to wait between passes). The driver has no sleep,
# clock or thread dependency. A sequential pass over the shards is correct for the
# exactly-once contract: each shard's commit is atomic and positions are per-shard.
#
# Generic over `[L: MultiShardChangeStreamListener, Store: ConditionalWriteStore]`;
# the listener and the writer are taken by `mut ref`. No pointer type appears.
# =============================================================================

from komira_snapshotter.change_stream_trait import (
    MultiShardChangeStreamListener,
    ChangeBatch,
)

from komira_objectstore.store import ConditionalWriteStore

from komira_iceberg import (
    IcebergTableWriter,
)

from .cdc_apply import (
    CdcApplyConfig,
    ApplyStats,
    apply_batch,
)
from .cdc_position import (
    ShardPositions,
)


# =============================================================================
# PassStats — the aggregate outcome of ONE ingest pass (all shards).
# =============================================================================


@fieldwise_init
struct PassStats(Copyable, Movable, Deinitable):
    """Aggregate counts across all shards for one `run_ingest_pass` (POD).

    Fields:
      var shards_polled: Int  — how many shards were polled this pass.
      var appended: Int       — total rows appended across shards.
      var deleted: Int        — total delete keys emitted across shards.
      var skipped: Int         — total records skipped (idempotence) across shards.
      var commits: Int         — how many shards issued a commit this pass.
    """

    var shards_polled: Int
    var appended: Int
    var deleted: Int
    var skipped: Int
    var commits: Int


# =============================================================================
# run_ingest_pass — one poll per shard, applied + committed.
# =============================================================================


def run_ingest_pass[
    L: MultiShardChangeStreamListener, Store: ConditionalWriteStore
](
    mut listener: L,
    mut writer: IcebergTableWriter[Store],
    config: CdcApplyConfig,
) raises -> PassStats:
    """Run ONE ingest pass over ALL currently-open shards.

    Derives the per-shard resume map from the committed table, lists the shards,
    and for each shard opens its iterator (after the derived position), polls one
    batch, and applies it as one atomic commit. Returns the aggregate PassStats.

    Crash-safety: the resume map is re-derived from the COMMITTED table at the
    START of the pass, so a crash mid-pass (before or after any shard's commit)
    is recovered on the next pass — a shard that committed is skipped by
    idempotence; a shard that did not is re-polled from its committed position."""
    # 1. Derive the resume map from the committed table (the exactly-once read),
    # reading through the writer's OWN store handle.
    var positions = ShardPositions.from_summary_kvs(writer.read_current_summary())

    # 2. List the open shards.
    var shard_ids = listener.list_shard_ids()

    var appended = 0
    var deleted = 0
    var skipped = 0
    var commits = 0

    # 3. Tail + apply each shard.
    for si in range(len(shard_ids)):
        var shard_id = shard_ids[si]
        var after = positions.get(shard_id)
        var cursor = listener.open_shard(shard_id, after)
        var batch = listener.poll(cursor)
        var stats = apply_batch(
            writer, config, shard_id, batch^, positions
        )
        appended += stats.appended
        deleted += stats.deleted
        skipped += stats.skipped
        if stats.committed:
            commits += 1

    return PassStats(len(shard_ids), appended, deleted, skipped, commits)


# =============================================================================
# run_ingest_loop — bounded pass loop (a bounded loop over passes, testable).
# =============================================================================


def run_ingest_loop[
    L: MultiShardChangeStreamListener, Store: ConditionalWriteStore
](
    mut listener: L,
    mut writer: IcebergTableWriter[Store],
    config: CdcApplyConfig,
    max_passes: Int,
) raises -> PassStats:
    """Run up to `max_passes` ingest passes, returning the AGGREGATE stats.

    A pass that produces NO commit (every shard idle / fully replayed) STOPS the
    loop early; the caller decides how to wait between idle waves. A bounded
    `max_passes` keeps the work per call finite. Each
    pass re-derives positions from the committed table, so the loop is crash-safe
    across passes (a re-run is a no-op once caught up)."""
    var total = PassStats(0, 0, 0, 0, 0)
    for _p in range(max_passes):
        var s = run_ingest_pass(listener, writer, config)
        total.shards_polled += s.shards_polled
        total.appended += s.appended
        total.deleted += s.deleted
        total.skipped += s.skipped
        total.commits += s.commits
        if s.commits == 0:
            break  # caught up (idle) — stop early.
    return total^
