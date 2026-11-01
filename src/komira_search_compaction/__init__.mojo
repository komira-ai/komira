# =============================================================================
# komira_search_compaction — merging small search splits into larger ones
# =============================================================================
#
# Query latency grows with the number of splits an index has, and ingest makes
# a small split per request. This package merges small splits so that the count
# stays bounded:
#
#   * select.mojo      the selection policy: `select_merge` picks at least
#                      `MERGE_FACTOR` small ingest splits, smallest first, up to
#                      `MAX_MERGE_FACTOR` and a byte cap. A pure function.
#   * merge_split.mojo the merge reducer: `merge_split_bytes` re-indexes K
#                      input splits into one, carrying the typed fast-field
#                      columns forward; `content_addressed_merge_key` names the
#                      merged object by its input set.
#   * reaper.mojo      `reap_retired_split` deletes a merged-away split's object
#                      once its grace period has passed.
#   * compact_once.mojo `compact_once` runs one pass: snapshot, select, merge,
#                      write the merged object and then append its summary to
#                      the reserved `_base` lineage, retire the inputs in their
#                      source lineages, and reap retired chunks, their objects
#                      and drained writer shards.
#
# The catalog (`SplitSummary`, `SearchMetastore`, the cross-shard reads) is
# `komira_search_catalog`; the split format and its readers are
# `komira_search`. Everything here is generic over `komira_objectstore`'s
# conditional-write store traits and names no cloud client.
# =============================================================================

from .select import (
    MergeCandidate,
    MergePlan,
    select_merge,
    SPLIT_DOC_TARGET,
    SPLIT_BYTE_TARGET,
    MERGE_FACTOR,
    MAX_MERGE_FACTOR,
    MAX_MERGED_BYTES,
)
from .merge_split import (
    merge_split_bytes,
    MergeResult,
    content_addressed_merge_key,
)
from .reaper import reap_retired_split
from .compact_once import (
    compact_once,
    CompactionConfig,
    CompactionResult,
    DEFAULT_GRACE_MS,
)
