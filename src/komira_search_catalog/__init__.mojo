"""`komira_search_catalog` — the durable split catalog of a search index:
which splits are published, retired and merged, across per-writer
sub-lineages. It is the store behind the `SearchIndexCatalog` seam of
`komira_search_scan`, built over a generic object store.

  * split_summary: `SplitSummary`, the catalog record for one published
    split, and its dependency-free binary codec.
  * metastore: `SearchMetastore[Storage]`, which publishes, lists, retires
    and reaps splits on one append-only manifest lineage; the cross-shard
    read over per-writer sub-lineages; and the reaper for drained writer
    shards.
  * generation: the durable records (a per-lineage generation floor and the
    index's retired-shards record) that keep the generation from going down
    when chunks and drained shards are reaped.

Everything is generic over `komira_objectstore`'s conditional-write store
traits. No cloud client is named here: the caller writes the split object
through whatever store it holds, then calls `SearchMetastore.publish`.
"""

from .split_summary import (
    SplitSummary,
    SPLIT_SUMMARY_VERSION,
    LiveSplitEntry,
    make_split_summary,
    make_merged_split_summary,
    encode_split_summary,
    decode_split_summary,
)
from .metastore import (
    SearchMetastore,
    ShardedLiveSplitEntry,
    make_shard_id,
    is_reserved_shard_id,
    shard_manifest_prefix,
    list_live_splits_across_shards,
    list_live_splits_across_shards_with_seq,
    generation_across_shards,
    LINEAGE_BASE_SHARD,
    reap_drained_shards,
    DrainedShardReapResult,
)
