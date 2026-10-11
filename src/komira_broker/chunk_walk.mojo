# =============================================================================
# komira_broker/chunk_walk.mojo
#   What a manifest walk does when a chunk read fails.
# =============================================================================
#
# Every offset-bearing walk over a broker manifest (`ConsumeCore.resolve_index`,
# the sub-lineage `_base` and block walks, the shard capture, the folded-prefix
# walk) reads `_LOG_START`, seeds a running offset from it, and reads chunks
# `[log_start_seq, head]`, adding each chunk's `record_count` to the running
# offset. A chunk it cannot read has an unknown `record_count`, so the walk can
# not continue with that running offset: every later chunk would be numbered
# too low by the missing count.
#
# A chunk at or above the `_LOG_START` the walk read can still read as
# `not_found` for one benign reason: retention advanced `_LOG_START` past it
# and a reaper deleted it after the walk read `_LOG_START` (reaping only
# deletes below `_LOG_START`). `restart_point_after_failed_read` tells the two
# cases apart by re-reading `_LOG_START`: past the chunk, the walk restarts
# from the new pointer (fresh seed, fresh seq, nothing kept from the old
# pass); otherwise the chunk is missing from the live range (a torn lineage)
# and the walk raises. Any other read error is re-raised unchanged.
#
# The `_base` key walk the fold's watermark reads keeps no offsets, but goes
# through the same helper: its key set must be the one the resolver's `_base`
# capture restarts to, and a torn `_base` must not silently lose a key.
#
# Each restart moves the walk's start strictly forward, and a walk ends at
# the head it read first, so a walk restarts at most once per chunk.
# =============================================================================

from komira_objectstore.cas_manifest import CasManifestStore, LogStart
from komira_objectstore.store import ConditionalWriteStore


def restart_point_after_failed_read[
    S: ConditionalWriteStore
](
    manifest: CasManifestStore[S], seq: Int64, var err: Error, walk: String
) raises -> LogStart:
    """A walk over `manifest` failed to read chunk `seq` with `err`. Returns
    the `_LOG_START` to restart the walk from when the chunk was reaped below
    a log start that advanced past it; raises `err` unchanged when it is not
    a not-found, and raises a torn-lineage error naming `walk` when the chunk
    is missing at or above the current log start."""
    if not is_not_found_msg(String(err)):
        raise err^
    var ls = manifest.read_log_start()
    if ls.log_start_seq > seq:
        return ls^
    raise Error(
        walk
        + ": chunk "
        + String(seq)
        + " is missing at or above _LOG_START seq "
        + String(ls.log_start_seq)
        + " (torn manifest lineage; refusing to renumber the chunks after it)"
    )


@always_inline
def is_not_found_msg(msg: String) -> Bool:
    """Classify a not-found / 404 store error message."""
    return (
        msg.find("not_found") >= 0
        or msg.find("NotFound") >= 0
        or msg.find("404") >= 0
        or msg.find("NoSuchKey") >= 0
    )
