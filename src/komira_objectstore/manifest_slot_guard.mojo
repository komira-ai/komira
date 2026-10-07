# =============================================================================
# komira_objectstore/manifest_slot_guard.mojo
#   The reaped-slot guard for the CAS manifest: a create that wins a slot
#   below `_LOG_START` is never reported committed.
# =============================================================================
#
# THE HOLE THIS CLOSES. `CasManifestStore` appends a chunk by creating
# `<prefix>/manifest/<seq>.chunk` with `If-None-Match: *` at the slot after the
# writer's view of the head. Retention advances `_LOG_START`, and the reaper then
# DELETEs the retired chunk keys. A conditional create cannot tell a deleted key
# from one that was never written, so a writer whose head is older than
# `_LOG_START` can WIN a slot that was already reaped. Every reader and every
# replay starts at `_LOG_START`, so that chunk is never read: acknowledging it
# loses the records.
#
# OPT-IN. The guard costs one GET per acknowledged append, so it runs only on a
# manifest that calls `CasManifestStore.enable_reaped_slot_guard()`. The broker
# enables it on every partition lineage it appends to (the partition manifest,
# its sub-lineages, the `_base` fold lineage and the produce WAL). The table
# store, shuffle and search do not, and pay nothing: none of the rules below
# runs for them.
#
# THE RULES (each is applied by `cas_manifest.mojo` at a call site; this module
# holds the decisions and the error text, so the protocol file only carries
# call-site edits):
#
#   1. After every winning chunk create, and before any `_HEAD` advance or
#      head-cache update, the writer GETs the `_LOG_START` body (no HEAD). If
#      `candidate_seq < log_start_seq` (`won_slot_is_reaped`) the append is NOT
#      committed: the writer invalidates its head cache and raises the
#      retryable `slot_reaped` error instead of acknowledging. This holds in
#      `_try_append_at` (append, append_idempotent, try_append_at_seq) and in
#      `AsyncManifestAppendOp`, where the read is its own parkable phase.
#   2. If that read fails, the writer FAILS CLOSED: no acknowledgement, the
#      head cache invalidated, and the `log_start_unread` error raised. The
#      append's outcome is then unknown (the chunk may be live), so the error is
#      retryable but is not a lost slot.
#   3. The forward probe (after a 412) never trusts a chunk below the log
#      start: when the slot it read is below `_LOG_START`
#      (`probed_slot_is_below_log_start`), or is gone (a 404: reaped since the
#      412), the writer recovers its head by LIST, which starts at the log
#      start. A chunk below the log start may be a refused win from rule 1 with
#      a different record count, and running offsets through it would ack
#      wrong offsets above the log start.
#   4. A writer deriving its head from the durable `_HEAD` object on the write
#      path clamps it: when `head.chunk_seq + 1 < log_start_seq`
#      (`head_is_below_log_start`) it recovers the head by LIST instead, so a
#      cold writer does not walk through reaped slots one refused create at a
#      time. Readers (`read_head`, `read_durable_head`) are not clamped.
#
# WHY RULE 1 IS EXACT. `reap` refuses any chunk at or above `_LOG_START`
# (`chunk_reclaim_guard.mojo`), and `_LOG_START` only moves forward (an If-Match
# CAS; every caller advances monotonically). So a key K is deleted only after
# `_LOG_START > K` is durable, and it stays `> K`. A create that wins a reaped K
# therefore reads `log_start_seq > K` afterwards and refuses. A create that wins
# a slot nobody reaped reads `log_start_seq <= K` unless retention retired K in
# the meantime (the race below).
#
# THE RACE RULE 1 DOES NOT RESOLVE (a duplicate, never a loss). A legitimate win
# at K, followed by another writer committing K+1 and retention retiring K, all
# before this writer's post-win GET, also reads `K < log_start_seq` and is
# refused as `slot_reaped`. The records at K were briefly in the live range, and
# the retry appends them again: a duplicate. Under `append_idempotent` the
# phantom scan starts at the log start, misses K, releases the sentinel, and the
# retry commits a second copy, so this window is an exactly-once breach. Nothing
# cheap tells the two cases apart: in BOTH the chunk at K is present and carries
# this writer's own etag (in the reaped case the writer's create is what put it
# there), so a GET or HEAD of K comparing etags would acknowledge the data-loss
# case. Telling them apart needs a per-seq retire record written by every
# retirer before its advance, which is a protocol change, not this guard. The
# window is one round trip and needs a second writer on the partition (a
# transaction marker, split compaction, or a displaced owner) plus a retention
# pass inside it. `tests/test_manifest_reaped_slot_guard_offline.mojo` pins the
# duplicate.
#
# WHERE THE GUARANTEE HOLDS. On S3, GCS and Azure (atomic If-None-Match create,
# atomic If-Match CAS, read-after-write consistency) and on a LocalFs root used
# by ONE process. LocalFs If-Match is not atomic across processes
# (`local_fs_conditional_store.mojo`): two processes sharing a root can move
# `_LOG_START` backward, which breaks the monotonicity rule 1 relies on.
#
# THE ERRORS MUST NEVER LOOK LIKE A LOST SLOT OR A FENCE, OR LIKE EACH OTHER.
# Classifiers in the tree match by substring: `is_precondition` and the
# coalescing spines' lost-slot checks match `412`, `precondition`,
# `If-None-Match`, `If-Match`; `is_lease_fenced` matches `lease_fenced`;
# `is_retryable_contention` matches `(retryable)` AND `exhausted`;
# `is_not_found` matches `not_found`, `status=404` and friends. A chunk key
# spells its sequence number in decimal and a prefix is caller-supplied, so the
# `slot_reaped` text carries NO digits, NO key and NO prefix. The
# `log_start_unread` text appends the cause for the operator, and a cause can
# spell anything (a topic named `slot_reaped` in a key path). So each refusal
# BEGINS with its own sentinel (`slot_reaped:` / `log_start_unread:`), and
# `is_slot_reaped` / `is_log_start_unread` match ONLY that leading token: text
# later in a message can never make it one of these. A caller that classifies
# tests `is_log_start_unread` first and both before any substring classifier
# (the broker's `classify_append_error` and `produce_error_for` do), so a
# wrapped cause never reaches the 412 checks.
#
# Encapsulation: pure functions over `Int64` and `String`; no store handle, no
# pointer, no origin, no I/O (so `cas_manifest.mojo` imports it without a cycle).
# =============================================================================


# The stable marker every reaped-slot refusal carries. Classify with
# `is_slot_reaped`, never by matching anything else in the message.
# Each refusal message BEGINS with its marker followed by `:`.
comptime SLOT_REAPED_MARKER: String = "slot_reaped:"

# The stable marker of the fail-closed refusal (rule 2), same shape.
comptime LOG_START_UNREAD_MARKER: String = "log_start_unread:"


@always_inline
def is_slot_reaped(msg: String) -> Bool:
    """True iff `msg` is the reaped-slot refusal: a create won a chunk slot below
    `_LOG_START`, so the append was NOT committed and was not acknowledged.

    The error is RETRYABLE: the writer's head cache has been invalidated, so a
    retry re-derives the head from the log start and lands at the live tail. It
    is NOT a 412 and NOT a lease fence. Under `append_idempotent` the staged
    dedup sentinel is released before the error re-raises.

    Matches only the LEADING sentinel, so a `log_start_unread` whose cause
    spells `slot_reaped` is never mistaken for this one."""
    return msg.startswith(SLOT_REAPED_MARKER)


@always_inline
def is_log_start_unread(msg: String) -> Bool:
    """True iff `msg` is the fail-closed refusal: the post-win `_LOG_START` read
    failed, so the append was not acknowledged and its outcome is unknown.
    Matches only the LEADING sentinel."""
    return msg.startswith(LOG_START_UNREAD_MARKER)


@always_inline
def won_slot_is_reaped(candidate_seq: Int64, log_start_seq: Int64) -> Bool:
    """True iff a create that just WON `candidate_seq` must not be acknowledged:
    the slot is below the live range `[log_start_seq, ...)`. `log_start_seq`
    must be read AFTER the win (module header, "why rule 1 is exact")."""
    return candidate_seq < log_start_seq


@always_inline
def probed_slot_is_below_log_start(taken_seq: Int64, log_start_seq: Int64) -> Bool:
    """True iff the forward probe's slot is below the live range, so its record
    count must not seed the next offset (rule 3)."""
    return taken_seq < log_start_seq


@always_inline
def head_is_below_log_start(head_chunk_seq: Int64, log_start_seq: Int64) -> Bool:
    """True iff a head read from the durable `_HEAD` object would aim the next
    create below `_LOG_START` (`head.chunk_seq + 1 < log_start_seq`, rule 4)."""
    return head_chunk_seq + Int64(1) < log_start_seq


def slot_reaped_error(site: String) -> Error:
    """The refusal raised instead of an acknowledgement. `site` names the verb;
    call sites pass a fixed literal. The text is free of digits, keys and
    prefixes (module header)."""
    return Error(
        SLOT_REAPED_MARKER
        + " CasManifestStore."
        + site
        + " (retryable): the create won a chunk slot below _LOG_START, a slot"
        + " retention already reaped; the append is NOT committed and was not"
        + " acknowledged. The head cache was invalidated; a retry re-derives"
        + " the head from the log start."
    )


def log_start_unread_error(site: String, cause: String) -> Error:
    """The fail-closed refusal (rule 2): the create won, but `_LOG_START` could
    not be read, so the write is not acknowledged. `cause` is the read error,
    kept for the operator; classify with `is_log_start_unread` first."""
    return Error(
        LOG_START_UNREAD_MARKER
        + " CasManifestStore."
        + site
        + ": the create won but _LOG_START could not be read after it, so the"
        + " append was not acknowledged (outcome unknown; retry the write)."
        + " cause: "
        + cause
    )
