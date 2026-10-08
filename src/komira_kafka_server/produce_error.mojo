# =============================================================================
# src/komira_kafka_server/produce_error.mojo — the Produce error code for a
# failed partition append
# =============================================================================
#
# The broker's append path raises `Error`s whose text carries stable tokens
# (the object store's CAS manifest writes them). `produce_error_for` maps such
# a message to the per-partition Produce error code the server returns:
#
#   message                                  code
#   ---------------------------------------  ------------------------------
#   log_start_unread (outcome unknown)       REQUEST_TIMED_OUT (7)
#   slot_reaped (a win below _LOG_START,     NOT_LEADER_OR_FOLLOWER (6)
#     not committed)
#   lease_fenced (a displaced writer)        NOT_LEADER_OR_FOLLOWER (6)
#   append retries exhausted (contention)    NOT_LEADER_OR_FOLLOWER (6)
#   anything else                            UNKNOWN_SERVER_ERROR (-1)
#
# NOT_LEADER_OR_FOLLOWER is retriable and means "this write did not happen":
# the client refreshes metadata and retries. That is exact for the three
# refusals that guarantee nothing was committed. `log_start_unread` cannot
# promise that (the chunk may be live), so it gets REQUEST_TIMED_OUT, whose
# meaning is "outcome unknown". It is tested FIRST: its message carries the
# cause of the failed read, which may contain any other marker.
#
# THE TOKENS ARE COPIES. This package depends on nothing, so it does not import
# `komira_objectstore`'s classifiers (that package links native code, and a
# dependency on it would keep this one from being a conda package). It matches
# the same tokens by the same rules instead:
#
#   token                 rule                  the store's classifier
#   --------------------  --------------------  -----------------------------
#   `slot_reaped:`        message starts with   is_slot_reaped
#   `log_start_unread:`   message starts with   is_log_start_unread
#   `lease_fenced`        message contains      is_lease_fenced
#   `(retryable)` AND     message contains      is_retryable_contention
#     `exhausted`           both
#
# The two sentinels match ONLY as the leading token: the `log_start_unread`
# text ends with a free-form cause that may spell any token, so text later in
# a message never makes it one of these.
#
# The drift check `komira//tests/kafka_produce_error_tokens` holds these copies
# equal to the store's tokens and these predicates in agreement with the
# store's classifiers. It is a `mojo_test` (run by `buck2 test`), because no
# library depends on both packages.
# =============================================================================

from komira_kafka_server.wire.produce_fetch import (
    ERROR_NOT_LEADER_OR_FOLLOWER,
    ERROR_REQUEST_TIMED_OUT,
    ERROR_UNKNOWN_SERVER_ERROR,
)

# The leading sentinel of the reaped-slot refusal.
comptime SLOT_REAPED_SENTINEL: String = "slot_reaped:"

# The leading sentinel of the fail-closed refusal (the post-win `_LOG_START`
# read failed; the outcome is unknown).
comptime LOG_START_UNREAD_SENTINEL: String = "log_start_unread:"

# The marker a writer-lease-epoch fence carries anywhere in its text.
comptime LEASE_FENCED_MARKER: String = "lease_fenced"

# The two markers the retry-budget-exhausted error carries; both must appear.
comptime CONTENTION_RETRYABLE_MARKER: String = "(retryable)"
comptime CONTENTION_EXHAUSTED_MARKER: String = "exhausted"


def is_slot_reaped_text(msg: String) -> Bool:
    """True iff `msg` begins with the reaped-slot sentinel (module header)."""
    return msg.startswith(SLOT_REAPED_SENTINEL)


def is_log_start_unread_text(msg: String) -> Bool:
    """True iff `msg` begins with the fail-closed sentinel (module header)."""
    return msg.startswith(LOG_START_UNREAD_SENTINEL)


def is_lease_fenced_text(msg: String) -> Bool:
    """True iff `msg` contains the lease-fence marker (module header)."""
    return msg.find(LEASE_FENCED_MARKER) >= 0


def is_retries_exhausted_text(msg: String) -> Bool:
    """True iff `msg` contains both retry-exhaustion markers (module header)."""
    return (
        msg.find(CONTENTION_RETRYABLE_MARKER) >= 0
        and msg.find(CONTENTION_EXHAUSTED_MARKER) >= 0
    )


def produce_error_for(msg: String) -> Int16:
    """The Produce error code for a failed append whose error text is `msg`
    (module header)."""
    if is_log_start_unread_text(msg):
        return ERROR_REQUEST_TIMED_OUT
    if is_slot_reaped_text(msg):
        return ERROR_NOT_LEADER_OR_FOLLOWER
    if is_lease_fenced_text(msg):
        return ERROR_NOT_LEADER_OR_FOLLOWER
    if is_retries_exhausted_text(msg):
        return ERROR_NOT_LEADER_OR_FOLLOWER
    return ERROR_UNKNOWN_SERVER_ERROR
