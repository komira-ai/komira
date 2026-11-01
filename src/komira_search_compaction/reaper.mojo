# =============================================================================
# komira_search_compaction/reaper.mojo — deleting the object of a merged-away split.
# =============================================================================
#
# The catalog's `reap_chunk` deletes only the manifest chunk of a retired
# split. The split object that chunk names (`summary.object_key`) is the
# compactor's to delete. Because reaping the chunk removes the only record of
# the key, the caller reads the key from the chunk BEFORE reaping it and
# passes it here.
#
# Deleting is idempotent (deleting an absent key succeeds), so a reap that was
# interrupted and is found again on a later run deletes the object again
# harmlessly.
#
# Generic over `ConditionalWriteStore`; the store is borrowed. No pointer
# appears in any signature.
# =============================================================================

from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore


def reap_retired_split[
    Store: ConditionalWriteStore
](
    store: Store,
    object_key: String,
    schedule_ts_ms: Int64,
    now_ms: Int64,
    grace_ms: Int64,
) raises -> Bool:
    """Delete the split object of a merged-away split once the grace period
    has passed.

    Deletes `object_key` only if `now_ms - schedule_ts_ms >= grace_ms`. That is
    the grace period which gates the reap of the manifest chunk, so a searcher
    that took its snapshot before the split was retired, and reads the split
    object directly, finishes before the object goes. `grace_ms` must exceed
    the longest query.

    Returns True if the object was deleted and False if the grace period has
    not yet passed; the caller then leaves it for a later run, because the
    retirement marker persists and the reap is found again. Deleting an object
    that is already gone is harmless, so a re-run returns True again."""
    if now_ms - schedule_ts_ms < grace_ms:
        return False
    store.delete(Path.parse(object_key))
    return True
