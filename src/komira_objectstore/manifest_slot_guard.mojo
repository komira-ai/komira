# =============================================================================
# komira_objectstore/manifest_slot_guard.mojo
#   The reaped-slot guard for the CAS manifest: a create that wins a slot
#   below `_LOG_START` is never reported committed.
# =============================================================================
#
# THE HOLE THIS CLOSES. `CasManifestStore` appends a chunk by creating
# `<prefix>/manifest/<seq>.chunk` with `If-None-Match: *` at the slot after
# the writer's view of the head. Retention advances `_LOG_START` and then
# `CasManifestStore.reap` DELETEs the retired chunk keys. A conditional create
# cannot tell a deleted key from one that was never written, so a writer whose
# head is older than `_LOG_START` can WIN a slot that was already reaped. Every
# reader and every replay starts at `_LOG_START`, so that chunk is never read:
# acknowledging it loses the records.
#
# THE GUARD (each rule below is applied by `cas_manifest.mojo` at a call site;
# this module holds the decisions and the error text, so the 3600-line
# protocol file only carries call-site edits):
#
#   1. After every winning chunk create, the writer GETs `_LOG_START`. If
#      `candidate_seq < log_start_seq`, the append is NOT committed: the writer
#      invalidates its local head cache and raises the retryable `slot_reaped`
#      error instead of acknowledging (`won_slot_is_reaped`,
#      `slot_reaped_error`).
#   2. `reap` refuses any `chunk_seq >= log_start_seq` (`reap_is_refused`).
#      With rule 3 this is what makes rule 1 sound.
#   3. `_LOG_START` only moves forward (`advance_log_start` is an If-Match CAS
#      and every caller advances monotonically).
#
#   Why 1 is sound: by 2, a chunk key K is deleted only after `_LOG_START > K`
#   is durable; by 3 it stays `> K`. So any create that wins a reaped K must
#   then read `log_start_seq > K` and refuse. A create that wins a slot that
#   was never written reads `log_start_seq <= K` (the slot is at or above the
#   live range), so the guard never refuses a real commit.
#
#   4. A writer deriving its head from the durable `_HEAD` object clamps it:
#      when `head.chunk_seq + 1 < log_start_seq` (`head_is_below_log_start`)
#      it recovers the head by LIST instead, so a cold writer does not walk
#      through reaped slots one refused create at a time.
#
# THE ERROR IS RETRYABLE AND MUST NEVER LOOK LIKE A LOST SLOT OR A FENCE.
# Every classifier in the tree matches by substring: `is_precondition` and the
# coalescing spines' lost-slot checks match `412`, `precondition`,
# `If-None-Match`, `If-Match`; `is_lease_fenced` matches `lease_fenced`;
# `is_retryable_contention` matches `(retryable)` AND `exhausted`;
# `is_not_found` matches `not_found`, `status=404` and friends. A chunk key
# spells its sequence number in decimal (`.../00000000000000000412.chunk`), and
# a prefix is caller-supplied, so the `slot_reaped` text carries NO digits, NO
# key and NO prefix: it is a fixed string that none of those classifiers can
# match. `tests/test_manifest_reaped_slot_guard_offline.mojo` pins that.
#
# Encapsulation: pure functions over `Int64` and `String`; no store handle, no
# pointer, no origin.
# =============================================================================


# The stable marker every reaped-slot refusal carries. Classify with
# `is_slot_reaped`, never by matching anything else in the message.
comptime SLOT_REAPED_MARKER: String = "slot_reaped"


@always_inline
def is_slot_reaped(msg: String) -> Bool:
    """True iff `msg` is the reaped-slot refusal: a create won a chunk slot below
    `_LOG_START`, so the append was NOT committed and was not acknowledged.

    The error is RETRYABLE: the writer's head cache has been invalidated, so a
    retry re-derives the head from the log start and lands at the live tail. It
    is NOT a lost slot (412) and NOT a lease fence: the writer may still own the
    partition. Under `append_idempotent` the staged dedup sentinel is released
    before the error re-raises, so the retry re-claims cleanly."""
    return msg.find(SLOT_REAPED_MARKER) >= 0


@always_inline
def won_slot_is_reaped(candidate_seq: Int64, log_start_seq: Int64) -> Bool:
    """True iff a create that just WON `candidate_seq` won a reaped slot: the
    slot is below the live range `[log_start_seq, ...)`, so no reader will ever
    read it. `log_start_seq` must be read AFTER the win (see the module header
    for why that order makes this exact)."""
    return candidate_seq < log_start_seq


def slot_reaped_error(site: String) -> Error:
    """The refusal raised instead of an acknowledgement. `site` names the verb
    (`append`, `apply_async_append_win`); call sites pass a fixed literal. The
    text is deliberately free of digits, keys and prefixes (module header)."""
    return Error(
        "CasManifestStore."
        + site
        + ": "
        + SLOT_REAPED_MARKER
        + " (retryable): the create won a chunk slot below _LOG_START, a slot"
        + " retention already reaped; the append is NOT committed and was not"
        + " acknowledged. The head cache was invalidated; a retry re-derives"
        + " the head from the log start."
    )


@always_inline
def head_is_below_log_start(head_chunk_seq: Int64, log_start_seq: Int64) -> Bool:
    """True iff a head read from the durable `_HEAD` object would aim the next
    create at a slot below `_LOG_START` (`head.chunk_seq + 1 < log_start_seq`).
    The writer then recovers its head by LIST (log-start aware) instead."""
    return head_chunk_seq + Int64(1) < log_start_seq


@always_inline
def reap_is_refused(chunk_seq: Int64, log_start_seq: Int64) -> Bool:
    """True iff `reap(chunk_seq)` must refuse: the chunk is still in the live
    range. A chunk may be deleted only once `_LOG_START` is durably past it,
    which is the invariant `won_slot_is_reaped` relies on."""
    return chunk_seq >= log_start_seq


def reap_refused_error(chunk_seq: Int64, log_start_seq: Int64) -> Error:
    """The refusal `reap` raises for a chunk at or above `_LOG_START`."""
    return Error(
        "CasManifestStore.reap: refused, chunk "
        + String(chunk_seq)
        + " is at or above log_start_seq "
        + String(log_start_seq)
        + "; advance the log start past a chunk before reaping it"
    )
