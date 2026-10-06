# =============================================================================
# src/komira_kafka_server/produce_error.mojo — the Produce error code for a
# failed partition append
# =============================================================================
#
# The broker's append path raises `Error`s classified by stable substrings
# (`komira_objectstore`'s classifiers). `produce_error_for` maps such a message
# to the per-partition Produce error code the server returns:
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
# =============================================================================

from komira_objectstore.cas_manifest import (
    is_lease_fenced,
    is_retryable_contention,
)
from komira_objectstore.manifest_slot_guard import (
    is_log_start_unread,
    is_slot_reaped,
)

from komira_kafka_server.wire.produce_fetch import (
    ERROR_NOT_LEADER_OR_FOLLOWER,
    ERROR_REQUEST_TIMED_OUT,
    ERROR_UNKNOWN_SERVER_ERROR,
)


def produce_error_for(msg: String) -> Int16:
    """The Produce error code for a failed append whose error text is `msg`
    (module header)."""
    if is_log_start_unread(msg):
        return ERROR_REQUEST_TIMED_OUT
    if is_slot_reaped(msg):
        return ERROR_NOT_LEADER_OR_FOLLOWER
    if is_lease_fenced(msg):
        return ERROR_NOT_LEADER_OR_FOLLOWER
    if is_retryable_contention(msg):
        return ERROR_NOT_LEADER_OR_FOLLOWER
    return ERROR_UNKNOWN_SERVER_ERROR
