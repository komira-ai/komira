# =============================================================================
# The secret capability reveals exactly its own node's secret
# =============================================================================
#
# `SecretCapability` is a handle that carries only a node id.
# `open_connection_for` lifts the plan's `SecretBindings` into a registry over
# the supplied store and reveals the secret bound to that id to a consumer.
# Nothing else in this package drives it, so this file does.
#
#   1. `node_id()` returns the id the capability was built with.
#   2. Over bindings {7 -> (db, ref-a)} and a `StaticSecretStore` scripted with
#      ref-a = "pw", the consumer is handed exactly the bytes "pw", once, after
#      exactly one store resolve.
#   3. Two capabilities (7 -> ref-a, 11 -> ref-b) over one bindings table each
#      reveal their own value.
#   4. A capability for an unbound node (8) raises and the consumer is never
#      called.
#   5. A ref removed from the store raises before the consumer is called.
#
# Which case guards which defect: a capability that always resolves the first
# bound entry fails 3 and 4; a `node_id()` that returns 0 fails 1 and 3; a
# deleted `reveal_for` call fails 2; a swallowed error fails 4 and 5.
#
# Offline and in-process: no sockets, no files, no cloud.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises

from komira_secret_registry.credential_consumer import CredentialConsumer
from komira_secret_registry.secret_bindings import SecretBindings
from komira_secret_store.secret_store import StaticSecretStore

from komira_sdk_exec.secret_capability import SecretCapability


comptime _NODE_A: Int = 7
comptime _NODE_B: Int = 11
comptime _NODE_UNBOUND: Int = 8
comptime _REF_A: String = "ref-a"
comptime _REF_B: String = "ref-b"
comptime _VALUE_A: String = "pw"
comptime _VALUE_B: String = "other-pw"


struct _RecordingConsumer(CredentialConsumer, Movable):
    """Copies the revealed bytes into an owned buffer (so the test can assert
    them after the reveal) and counts invocations. It never retains the `Span`."""

    var seen: List[UInt8]
    var consume_count: Int

    def __init__(out self):
        self.seen = List[UInt8]()
        self.consume_count = 0

    def consume(mut self, secret: Span[UInt8, _]) raises:
        self.consume_count += 1
        self.seen = List[UInt8]()
        for i in range(len(secret)):
            self.seen.append(secret[i])


def _assert_seen(
    consumer: _RecordingConsumer, expected: String, what: String
) raises:
    """The consumer's last reveal was exactly `expected`, byte for byte."""
    var want = expected.as_bytes()
    assert_equal(len(consumer.seen), len(want), what + ": revealed byte count")
    for i in range(len(want)):
        assert_equal(consumer.seen[i], want[i], what + ": revealed byte")


def _store() -> StaticSecretStore:
    """A store scripted with ref-a = pw and ref-b = other-pw."""
    var store = StaticSecretStore()
    store.put(_REF_A, _VALUE_A)
    store.put(_REF_B, _VALUE_B)
    return store^


def _bindings() -> SecretBindings:
    """Node 7 bound to ref-a and node 11 bound to ref-b."""
    var bindings = SecretBindings()
    bindings.bind(_NODE_A, String("db"), String(_REF_A))
    bindings.bind(_NODE_B, String("warehouse"), String(_REF_B))
    return bindings^


def test_node_id_is_the_id_it_was_built_with() raises:
    assert_equal(SecretCapability(_NODE_A).node_id(), _NODE_A, "node 7")
    assert_equal(SecretCapability(_NODE_B).node_id(), _NODE_B, "node 11")


def test_reveal_hands_the_consumer_exactly_the_bound_bytes_once() raises:
    var bindings = SecretBindings()
    bindings.bind(_NODE_A, String("db"), String(_REF_A))
    var store = StaticSecretStore()
    store.put(_REF_A, _VALUE_A)
    var probe = store.share()
    var consumer = _RecordingConsumer()

    SecretCapability(_NODE_A).open_connection_for[
        StaticSecretStore, _RecordingConsumer
    ](bindings, store^, consumer)

    assert_equal(consumer.consume_count, 1, "consumed exactly once")
    _assert_seen(consumer, _VALUE_A, "node 7")
    assert_equal(probe.resolve_count(), 1, "exactly one store resolve")


def test_two_capabilities_each_reveal_their_own_value() raises:
    var bindings = _bindings()
    var store = _store()
    var probe = store.share()
    var consumer = _RecordingConsumer()

    var cap_a = SecretCapability(_NODE_A)
    var cap_b = SecretCapability(_NODE_B)
    assert_equal(cap_a.node_id(), _NODE_A, "capability a carries node 7")
    assert_equal(cap_b.node_id(), _NODE_B, "capability b carries node 11")

    cap_a.open_connection_for[StaticSecretStore, _RecordingConsumer](
        bindings, store.share(), consumer
    )
    _assert_seen(consumer, _VALUE_A, "capability for node 7")

    cap_b.open_connection_for[StaticSecretStore, _RecordingConsumer](
        bindings, store^, consumer
    )
    _assert_seen(consumer, _VALUE_B, "capability for node 11")

    assert_equal(consumer.consume_count, 2, "one reveal per capability")
    assert_equal(probe.resolve_count(), 2, "one resolve per capability")


def test_unbound_node_raises_and_the_consumer_is_never_called() raises:
    var bindings = _bindings()
    var store = _store()
    var probe = store.share()
    var consumer = _RecordingConsumer()

    with assert_raises():
        SecretCapability(_NODE_UNBOUND).open_connection_for[
            StaticSecretStore, _RecordingConsumer
        ](bindings, store^, consumer)

    assert_equal(consumer.consume_count, 0, "the consumer was never called")
    assert_equal(probe.resolve_count(), 0, "the store was never consulted")


def test_removed_ref_raises_before_the_consumer_is_called() raises:
    var bindings = _bindings()
    var store = _store()
    var probe = store.share()
    probe.remove(_REF_A)
    var consumer = _RecordingConsumer()

    with assert_raises():
        SecretCapability(_NODE_A).open_connection_for[
            StaticSecretStore, _RecordingConsumer
        ](bindings, store^, consumer)

    assert_equal(consumer.consume_count, 0, "the consumer was never called")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
