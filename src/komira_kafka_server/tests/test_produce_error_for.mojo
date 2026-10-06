# =============================================================================
# tests/test_produce_error_for.mojo — the Produce error code for an append error
# =============================================================================
#
# Feeds `produce_error_for` the REAL error texts `komira_objectstore` raises
# (built by the same functions the manifest calls), so a change to a marker
# breaks this test rather than silently remapping a produce error. Each case
# names the mutant it catches.
# =============================================================================

from std.testing import assert_equal

from komira_objectstore.manifest_slot_guard import (
    log_start_unread_error,
    slot_reaped_error,
)

from komira_kafka_server.produce_error import produce_error_for
from komira_kafka_server.wire.produce_fetch import (
    ERROR_NOT_LEADER_OR_FOLLOWER,
    ERROR_REQUEST_TIMED_OUT,
    ERROR_UNKNOWN_SERVER_ERROR,
)


def test_slot_reaped_is_not_leader() raises:
    # Mutant: slot_reaped unmapped (falls to UNKNOWN_SERVER_ERROR, which the
    # client does not retry).
    for site in [String("append"), String("async_append")]:
        assert_equal(
            produce_error_for(String(slot_reaped_error(site))),
            ERROR_NOT_LEADER_OR_FOLLOWER,
            "a win in a reaped slot: not committed, retriable NOT_LEADER",
        )


def test_log_start_unread_is_timed_out_even_with_other_markers() raises:
    # Mutant: the slot_reaped / lease checks run first (a cause that spells
    # another marker would then claim "not written" for an unknown outcome).
    var cause = String("status=503 slot_reaped lease_fenced (retryable) exhausted")
    assert_equal(
        produce_error_for(String(log_start_unread_error(String("append"), cause))),
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
