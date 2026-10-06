# =============================================================================
# komira_objectstore/chunk_reclaim_guard.mojo
#   The rules that keep chunk reclamation off live chunks.
# =============================================================================
#
# `_LOG_START.log_start_seq` is the lowest LIVE chunk: every reader and every
# replay starts there. A chunk at or above it is live, whatever tombstone it
# carries. Callers retire a chunk in this order:
#
#   1. advance `_LOG_START` past it,
#   2. tombstone it (or tombstone first: a tombstone on a live chunk is
#      harmless, see below),
#   3. reap it after the grace window.
#
# A tombstone on a chunk at or above `_LOG_START` (an advance that failed
# after the tombstone, or a crash between the two) is STRANDED, not
# reclaimable. `CasManifestStore.reap` refuses such a chunk (`reap_is_refused`)
# and the broker's `ReapWorker` skips and counts it before it deletes anything.
# A later pass that advances `_LOG_START` makes the tombstone reclaimable.
#
# `CasManifestStore.rewrite_chunk_body` overwrites a chunk with an If-Match on
# the etag it read, so a chunk reaped between its read and its write is never
# recreated (`rewrite_target_deleted_error`). The message carries `not_found`,
# the absence token `is_not_found` matches, so a caller that tolerates a chunk
# that is already gone keeps doing so.
#
# `CasManifestStore.advance_log_start` never moves `_LOG_START` backwards
# (`advance_would_regress`): a pointer that went back would make reaped
# chunks look live again.
#
# `CasManifestStore.purge_all` is outside these rules: it reclaims a WHOLE
# lineage (every chunk and `_LOG_START` itself) once its caller has decided
# that nothing reads the lineage any more.
#
# A tombstone also says what the reaper may reclaim BESIDES the chunk key. A
# chunk body may name payload objects (the broker's `.seg`). A retention
# tombstone retires the payload with the chunk. A tombstone written with
# `payload_moved` retires only the chunk: another manifest now references
# the payload (a sub-lineage migration or segment fold re-recorded it into
# `_base`), so that manifest's own retention owns it. The tombstone body:
#
#   [ schedule_ts_ms: i64 LE ]                  retention tombstone (8 bytes)
#   [ schedule_ts_ms: i64 LE ][ flags: u8 ]     payload moved (9 bytes)
#
# An 8-byte body (every tombstone written before the flag existed) decodes as
# `payload_moved = False`. Any nonzero flags byte decodes as `payload_moved =
# True`, so a flag this reader does not know never causes a delete. A reaper
# built before the flag existed reads only the first 8 bytes and would delete
# the payload: upgrade reapers before running a migration or a fold.
#
# This module holds decisions, the tombstone body codec and error text only;
# it does no I/O, so `cas_manifest.mojo` imports it without a cycle.
# =============================================================================


@always_inline
def reap_is_refused(chunk_seq: Int64, log_start_seq: Int64) -> Bool:
    """True iff reaping `chunk_seq` would delete a live chunk: it is at or
    above the lowest live chunk `log_start_seq`."""
    return chunk_seq >= log_start_seq


def reap_refused_error(chunk_seq: Int64, log_start_seq: Int64) -> Error:
    """The error `CasManifestStore.reap` raises for a live chunk. It carries no
    absence or precondition token, so no caller mistakes it for a lost race or
    an already-reaped chunk."""
    return Error(
        "CasManifestStore.reap: refused, chunk "
        + String(chunk_seq)
        + " is at or above log_start_seq "
        + String(log_start_seq)
        + "; advance the log start past a chunk before reaping it"
    )


def rewrite_target_deleted_error(chunk_seq: Int64) -> Error:
    """The error `CasManifestStore.rewrite_chunk_body` raises when the chunk
    was deleted (reaped) between its read and its conditional write. The
    write did not recreate the chunk."""
    return Error(
        "CasManifestStore.rewrite_chunk_body: chunk "
        + String(chunk_seq)
        + " not_found: it was deleted during the rewrite and was not recreated"
    )


@always_inline
def advance_would_regress(
    cur_seq: Int64, cur_offset: Int64, new_seq: Int64, new_offset: Int64
) -> Bool:
    """True iff advancing `_LOG_START` from (cur_seq, cur_offset) to
    (new_seq, new_offset) would move either coordinate backwards. A pointer
    that went back would make reaped chunks look live again."""
    return new_seq < cur_seq or new_offset < cur_offset


def advance_regress_error(
    cur_seq: Int64, cur_offset: Int64, new_seq: Int64, new_offset: Int64
) -> Error:
    """The error `CasManifestStore.advance_log_start` raises for a backwards
    target. It is precondition-shaped (a stale view lost to a newer pointer),
    so a caller that retries on a lost CAS re-reads and stops."""
    return Error(
        "CasManifestStore.advance_log_start: precondition (412), refusing to"
        " move _LOG_START backwards from (seq "
        + String(cur_seq)
        + ", offset "
        + String(cur_offset)
        + ") to (seq "
        + String(new_seq)
        + ", offset "
        + String(new_offset)
        + ")"
    )


# =============================================================================
# Tombstone body codec
# =============================================================================

comptime TOMBSTONE_TS_BYTES = 8
comptime TOMBSTONE_FLAG_PAYLOAD_MOVED = UInt8(1)


@fieldwise_init
struct Tombstone(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """A decoded tombstone marker.

    Field layout:
      var schedule_ts_ms: Int64 — when the chunk was retired (ms); the reaper
                                  counts its grace window from here.
      var payload_moved: Bool   — True: reclaim the chunk key only; the
                                  payload objects its body names belong to
                                  another manifest now.
    """

    var schedule_ts_ms: Int64
    var payload_moved: Bool


def encode_tombstone_body(
    schedule_ts_ms: Int64, payload_moved: Bool
) -> List[UInt8]:
    """The tombstone body. Without `payload_moved` it is the 8-byte body every
    tombstone had before the flag existed, byte for byte."""
    var out = List[UInt8]()
    var u = UInt64(schedule_ts_ms)
    for i in range(TOMBSTONE_TS_BYTES):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))
    if payload_moved:
        out.append(TOMBSTONE_FLAG_PAYLOAD_MOVED)
    return out^


def decode_tombstone_body(bytes: List[UInt8]) raises -> Tombstone:
    """Decode a tombstone body. Raises on a body shorter than its timestamp.
    An 8-byte body is a retention tombstone; a nonzero flags byte after the
    timestamp means the payload moved."""
    if len(bytes) < TOMBSTONE_TS_BYTES:
        raise Error(
            "tombstone body: truncated, "
            + String(len(bytes))
            + " bytes (want at least 8)"
        )
    var u = UInt64(0)
    for i in range(TOMBSTONE_TS_BYTES):
        u |= UInt64(Int(bytes[i])) << UInt64(8 * i)
    var moved = (
        len(bytes) > TOMBSTONE_TS_BYTES
        and bytes[TOMBSTONE_TS_BYTES] != UInt8(0)
    )
    return Tombstone(schedule_ts_ms=Int64(u), payload_moved=moved)
