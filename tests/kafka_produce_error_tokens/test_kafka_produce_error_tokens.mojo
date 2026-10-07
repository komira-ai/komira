# =============================================================================
# tests/kafka_produce_error_tokens/test_kafka_produce_error_tokens.mojo
#   komira_kafka_server's copies of komira_objectstore's append-error tokens
#   cannot drift from the store's.
# =============================================================================
#
# `komira_kafka_server.produce_error` classifies an append error by its own
# copies of the store's tokens (BUCK says why). Two checks hold them together:
#
#   1. EQUALITY. Each copy equals the store's constant where the store names
#      one: `SLOT_REAPED_MARKER`, `LOG_START_UNREAD_MARKER` and the
#      module-private `_LEASE_FENCED_MARKER` (imported here only to compare
#      it). Mutant: any copied sentinel or marker changed by one byte.
#   2. AGREEMENT. Each kafka predicate returns what the store's classifier
#      returns on a corpus built from BOTH sides' tokens and from the store's
#      real error texts. This covers the exhaustion markers, which the store
#      spells inline in `is_retryable_contention`, and the matching RULE
#      (leading token vs anywhere). Mutants: the store's `(retryable)` or
#      `exhausted` respelled; a sentinel matched anywhere instead of leading.
#
# Then `produce_error_for` is fed the store's real texts, built by the store's
# own builders, and must give the documented codes.
# =============================================================================

from std.testing import assert_equal

from komira_objectstore.cas_manifest import (
    _LEASE_FENCED_MARKER,
    is_lease_fenced,
    is_retryable_contention,
)
from komira_objectstore.manifest_slot_guard import (
    LOG_START_UNREAD_MARKER,
    SLOT_REAPED_MARKER,
    is_log_start_unread,
    is_slot_reaped,
    log_start_unread_error,
    slot_reaped_error,
)

from komira_kafka_server.produce_error import (
    CONTENTION_EXHAUSTED_MARKER,
    CONTENTION_RETRYABLE_MARKER,
    LEASE_FENCED_MARKER,
    LOG_START_UNREAD_SENTINEL,
    SLOT_REAPED_SENTINEL,
    is_lease_fenced_text,
    is_log_start_unread_text,
    is_retries_exhausted_text,
    is_slot_reaped_text,
    produce_error_for,
)
from komira_kafka_server.wire.produce_fetch import (
    ERROR_NOT_LEADER_OR_FOLLOWER,
    ERROR_REQUEST_TIMED_OUT,
)


def _store_lease_fenced_text() -> String:
    """The shape of `CasManifestStore.append`'s lease-fence error, built on the
    store's own marker."""
    return (
        "CasManifestStore.append: "
        + _LEASE_FENCED_MARKER
        + " — writer_lease_epoch 1 < current_lease_epoch 2"
        + " (stale displaced writer rejected before taking an offset)"
    )


def _store_exhausted_text() -> String:
    """The text of `CasManifestStore.append`'s retry-budget-exhausted error."""
    return (
        "CasManifestStore.append: exhausted 8 retries under contention"
        " (retryable) — prefix=p"
    )


def _corpus() -> List[String]:
    """Probes built from both sides' tokens, alone, leading, trailing and
    combined, plus the store's real texts."""
    var tokens = List[String]()
    tokens.append(String(SLOT_REAPED_SENTINEL))
    tokens.append(String(LOG_START_UNREAD_SENTINEL))
    tokens.append(String(LEASE_FENCED_MARKER))
    tokens.append(String(CONTENTION_RETRYABLE_MARKER))
    tokens.append(String(CONTENTION_EXHAUSTED_MARKER))
    tokens.append(String(SLOT_REAPED_MARKER))
    tokens.append(String(LOG_START_UNREAD_MARKER))
    tokens.append(String(_LEASE_FENCED_MARKER))
    var out = List[String]()
    out.append(String(""))
    out.append(String("segment PUT failed: status=500"))
    for t in tokens:
        out.append(t)
        out.append(t + " tail")
        out.append(String("head ") + t)
        for u in tokens:
            out.append(t + " " + u)
    out.append(String(slot_reaped_error(String("append"))))
    out.append(String(slot_reaped_error(String("async_append"))))
    out.append(
        String(
            log_start_unread_error(
                String("append"),
                String("status=503 slot_reaped: lease_fenced (retryable) exhausted"),
            )
        )
    )
    out.append(_store_lease_fenced_text())
    out.append(_store_exhausted_text())
    return out^


def test_copied_tokens_equal_the_store_tokens() raises:
    # Mutant: a copied sentinel or marker respelled on either side.
    assert_equal(String(SLOT_REAPED_SENTINEL), String(SLOT_REAPED_MARKER))
    assert_equal(
        String(LOG_START_UNREAD_SENTINEL), String(LOG_START_UNREAD_MARKER)
    )
    assert_equal(String(LEASE_FENCED_MARKER), String(_LEASE_FENCED_MARKER))


def test_predicates_agree_with_store_classifiers() raises:
    # Mutants: the store's exhaustion markers respelled, or a matching rule
    # changed (a leading-token match made a substring match) on either side.
    var corpus = _corpus()
    for msg in corpus:
        assert_equal(
            is_slot_reaped_text(msg), is_slot_reaped(msg), "slot_reaped: " + msg
        )
        assert_equal(
            is_log_start_unread_text(msg),
            is_log_start_unread(msg),
            "log_start_unread: " + msg,
        )
        assert_equal(
            is_lease_fenced_text(msg), is_lease_fenced(msg), "lease_fenced: " + msg
        )
        assert_equal(
            is_retries_exhausted_text(msg),
            is_retryable_contention(msg),
            "retries exhausted: " + msg,
        )


def test_store_texts_map_to_documented_codes() raises:
    # Mutant: a store text that no longer reaches its code through the copies.
    for site in [String("append"), String("async_append")]:
        assert_equal(
            produce_error_for(String(slot_reaped_error(site))),
            ERROR_NOT_LEADER_OR_FOLLOWER,
        )
    assert_equal(
        produce_error_for(
            String(
                log_start_unread_error(
                    String("append"), String("slot_reaped: lease_fenced")
                )
            )
        ),
        ERROR_REQUEST_TIMED_OUT,
    )
    assert_equal(
        produce_error_for(_store_lease_fenced_text()),
        ERROR_NOT_LEADER_OR_FOLLOWER,
    )
    assert_equal(
        produce_error_for(_store_exhausted_text()), ERROR_NOT_LEADER_OR_FOLLOWER
    )


def main() raises:
    test_copied_tokens_equal_the_store_tokens()
    test_predicates_agree_with_store_classifiers()
    test_store_texts_map_to_documented_codes()
    print("ALL kafka produce-error token drift checks PASSED")
