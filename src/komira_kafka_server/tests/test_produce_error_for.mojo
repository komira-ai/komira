# =============================================================================
# tests/test_produce_error_for.mojo — the Produce error code for an append error
# =============================================================================
#
# Feeds `produce_error_for` the error texts `komira_objectstore` raises, as
# literal copies (this package does not depend on the store). The copies of the
# tokens inside them are held equal to the store's by the drift check
# `komira//tests/kafka_produce_error_tokens`. Each case names the mutant it
# catches.
# =============================================================================

from std.testing import assert_equal

from komira_kafka_server.produce_error import produce_error_for
from komira_kafka_server.wire.produce_fetch import (
    ERROR_NOT_LEADER_OR_FOLLOWER,
    ERROR_REQUEST_TIMED_OUT,
    ERROR_UNKNOWN_SERVER_ERROR,
)


def slot_reaped_text(site: String) -> String:
    """The text of `komira_objectstore`'s `slot_reaped_error(site)`."""
    return (
        "slot_reaped: CasManifestStore."
        + site
        + " (retryable): the create won a chunk slot below _LOG_START, a slot"
        + " retention already reaped; the append is NOT committed and was not"
        + " acknowledged. The head cache was invalidated; a retry re-derives"
        + " the head from the log start."
    )


def log_start_unread_text(site: String, cause: String) -> String:
    """The text of `komira_objectstore`'s `log_start_unread_error(site, cause)`.
    """
    return (
        "log_start_unread: CasManifestStore."
        + site
        + ": the create won but _LOG_START could not be read after it, so the"
        + " append was not acknowledged (outcome unknown; retry the write)."
        + " cause: "
        + cause
    )


def test_slot_reaped_is_not_leader() raises:
    # Mutant: slot_reaped unmapped (falls to UNKNOWN_SERVER_ERROR, which the
    # client does not retry).
    for site in [String("append"), String("async_append")]:
        assert_equal(
            produce_error_for(slot_reaped_text(site)),
            ERROR_NOT_LEADER_OR_FOLLOWER,
            "a win in a reaped slot: not committed, retriable NOT_LEADER",
        )


def test_log_start_unread_is_timed_out_even_with_other_markers() raises:
    # Mutant: the slot_reaped / lease checks run first (a cause that spells
    # another marker would then claim "not written" for an unknown outcome).
    var cause = String("status=503 slot_reaped lease_fenced (retryable) exhausted")
    assert_equal(
        produce_error_for(log_start_unread_text(String("append"), cause)),
        ERROR_REQUEST_TIMED_OUT,
        "an unread _LOG_START after a win: outcome unknown",
    )


def test_lease_fenced_and_exhaustion_are_not_leader() raises:
    assert_equal(
        produce_error_for(
            String("CasManifestStore.append: lease_fenced — writer_lease_epoch 1")
        ),
        ERROR_NOT_LEADER_OR_FOLLOWER,
        "a displaced writer",
    )
    assert_equal(
        produce_error_for(
            String(
                "CasManifestStore.append: exhausted 8 retries under contention"
                " (retryable) — prefix=p"
            )
        ),
        ERROR_NOT_LEADER_OR_FOLLOWER,
        "the slot could not be won within the retry budget",
    )


def test_anything_else_is_unknown() raises:
    assert_equal(
        produce_error_for(String("segment PUT failed: status=500")),
        ERROR_UNKNOWN_SERVER_ERROR,
        "an unclassified failure",
    )
    assert_equal(
        produce_error_for(String("precondition failed (412)")),
        ERROR_UNKNOWN_SERVER_ERROR,
        "a bare 412 never reaches the produce response as NOT_LEADER here",
    )


def main() raises:
    test_slot_reaped_is_not_leader()
    test_log_start_unread_is_timed_out_even_with_other_markers()
    test_lease_fenced_and_exhaustion_are_not_leader()
    test_anything_else_is_unknown()
    print("ALL produce_error_for tests PASSED")
