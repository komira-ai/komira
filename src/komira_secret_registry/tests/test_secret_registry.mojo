# =============================================================================
# komira_secret_registry/tests/test_secret_registry.mojo: GATE TEST for the
#   per-execution SecretRegistry and the connector reveal seam.
# =============================================================================
#
# This test imports nothing outside the registry's own dependency closure:
# `komira_secret_store` (the `SecretStore` trait, `StaticSecretStore`,
# `SecretValue`), `komira_crypto` (the zeroize helper), and `komira_core` (the
# store-less `SecretBindings` table). The test declares no extra dependencies,
# so a new import of a package outside that closure fails to COMPILE here. It
# does not pass by reaching further.
#
# The properties of a composed store, an authorization deny and an audit
# record on the resolve path, belong to that composition, not to the registry.
# They are tested where such a composition is built.
#
# The falsifiers, each over a bare `StaticSecretStore` (its `resolve_count` is
# the consulted / not-consulted proof):
#
#   (a) RESOLVE-THROUGH: a registered node's reveal hands the consumer exactly
#       the store's scripted bytes, and the store is consulted exactly once.
#   (b) RESOLVE-ON-DEMAND: the registry holds no value. After the store rotates
#       the same `secret_ref`, the next reveal sees the NEW value, and every
#       reveal is its own resolve.
#   (c) STORE ERROR PROPAGATES: a bound node whose `secret_ref` the store cannot
#       resolve RAISES, and the consumer is never called.
#   (d) WIPED-AT-EXIT: the zeroize contract on the helper `SecretValue`'s
#       destructor uses, plus a registry that revealed a value tearing down
#       cleanly.
#   (e) UNBOUND node_id: `reveal_for` on an unregistered node RAISES before the
#       store is reached (fail-closed, never a silent local fallback).
#   (f) FROM-BINDINGS: `SecretRegistry.from_bindings` lifts every row of a
#       `SecretBindings` table, each row reveals its own value, and a node
#       outside the table stays unbound.
#   (g) INTO-STORE: `into_store` hands back the SAME store, carrying the
#       resolves made through the registry.
#
# Offline and in-process: no sockets, no files, no cloud.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_crypto import zeroize_inline_array

from komira_core.plan.secret_bindings import SecretBindings

from komira_secret_store.secret_store import StaticSecretStore
from komira_secret_store.secret_value import MAX_SECRET_LEN

from komira_secret_registry.credential_consumer import CredentialConsumer
from komira_secret_registry.secret_registry import SecretRegistry


comptime _Registry = SecretRegistry[StaticSecretStore]

comptime _SECRET: String = "postgresql://app:s3cr3t@db.example.com:5432/prod"
comptime _ROTATED: String = "postgresql://app:r0t4t3d@db.example.com:5432/prod"
comptime _SECRET_REF: String = "ref-abc"
comptime _NAME_HANDLE: String = "prod-pg"
comptime _NODE_ID: Int = 7

comptime _OTHER_SECRET: String = "token-for-the-second-binding"
comptime _OTHER_REF: String = "ref-xyz"
comptime _OTHER_HANDLE: String = "s3-bucket"
comptime _OTHER_NODE_ID: Int = 11


struct _RecordingConsumer(CredentialConsumer, Movable):
    """A `CredentialConsumer` that copies the revealed bytes into an owned buffer
    (so the test can assert them after the reveal) and counts invocations. It
    copies out of the scoped `Span` and never retains it (escape = a compile
    error)."""

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


def _assert_seen(consumer: _RecordingConsumer, expected: String, what: String) raises:
    """The consumer's LAST reveal was exactly `expected`, byte for byte."""
    var want = expected.as_bytes()
    assert_equal(len(consumer.seen), len(want), what + ": revealed byte count")
    for i in range(len(want)):
        assert_equal(consumer.seen[i], want[i], what + ": revealed byte")


def _scripted_store() -> StaticSecretStore:
    """A `StaticSecretStore` scripted with the known `secret_ref -> value`."""
    var store = StaticSecretStore()
    store.put(_SECRET_REF, _SECRET)
    return store^


def _registry(var store: StaticSecretStore) -> _Registry:
    """A registry over `store` with `_NODE_ID -> (_NAME_HANDLE, _SECRET_REF)`."""
    var reg = _Registry(store^)
    reg.register(_NODE_ID, String(_NAME_HANDLE), String(_SECRET_REF))
    return reg^


# (a) resolve-through: the revealed bytes ARE the scripted value.
def test_resolve_through_registry_reveals_scripted_value() raises:
    var store = _scripted_store()
    var probe = store.share()
    var reg = _registry(store^)
    assert_equal(reg.num_entries(), 1, "one binding registered")
    assert_true(reg.has_binding(_NODE_ID), "the registered node is bound")

    var consumer = _RecordingConsumer()
    reg.reveal_for[_RecordingConsumer](_NODE_ID, consumer)

    assert_equal(consumer.consume_count, 1, "the reveal consumed exactly once")
    _assert_seen(consumer, _SECRET, "resolve-through")
    assert_equal(probe.resolve_count(), 1, "the store was consulted once")


# (b) resolve-on-demand: no value is cached in the registry.
def test_every_reveal_resolves_and_sees_a_rotation() raises:
    var store = _scripted_store()
    var probe = store.share()
    var reg = _registry(store^)

    var consumer = _RecordingConsumer()
    reg.reveal_for[_RecordingConsumer](_NODE_ID, consumer)
    _assert_seen(consumer, _SECRET, "before rotation")

    # The customer rotates the secret in their store: same ref, new value.
    probe.put(_SECRET_REF, _ROTATED)
    reg.reveal_for[_RecordingConsumer](_NODE_ID, consumer)
    _assert_seen(consumer, _ROTATED, "after rotation")

    assert_equal(consumer.consume_count, 2, "two reveals, two consumes")
    assert_equal(
        probe.resolve_count(), 2, "each reveal is its own resolve (nothing cached)"
    )


# (c) a store error propagates, and the consumer is never called.
def test_unresolvable_ref_raises_before_the_consumer() raises:
    var store = _scripted_store()
    var probe = store.share()
    var reg = _registry(store^)

    # The customer deletes the secret; the binding still names its ref.
    probe.remove(_SECRET_REF)
    assert_true(reg.has_binding(_NODE_ID), "the binding outlives the secret")

    var consumer = _RecordingConsumer()
    with assert_raises(contains="no secret for secret_ref"):
        reg.reveal_for[_RecordingConsumer](_NODE_ID, consumer)

    assert_equal(probe.resolve_count(), 1, "the store WAS asked, and refused")
    assert_equal(consumer.consume_count, 0, "a refused resolve never reaches the consumer")


# (d) wiped-at-exit.
def test_secret_wiped_at_registry_drop() raises:
    # The FUNCTIONAL zeroize contract: the SAME helper `SecretValue`'s destructor
    # uses zeroes a buffer of the SAME inline-array shape.
    var buf = Array[UInt8, MAX_SECRET_LEN](fill=UInt8(0xCB))
    for i in range(8):
        assert_equal(Int(buf[i]), 0xCB, "pre: byte is 0xCB")
    zeroize_inline_array(buf)
    for i in range(MAX_SECRET_LEN):
        assert_equal(Int(buf[i]), 0, "post: every byte is zeroed (the wipe contract)")

    # The STRUCTURAL drop: a registry that revealed a value tears down through
    # the whole RAII chain. The per-reveal `SecretValue` was dropped (and wiped)
    # at `reveal_for`'s exit; the registry holds no `SecretValue` field, so its
    # own drop frees only the bindings and the store. A buffer cannot be read
    # after drop (it is unmappable), so the disassembly proof stays with the
    # secret-value foundation.
    var reg = _registry(_scripted_store())
    var consumer = _RecordingConsumer()
    reg.reveal_for[_RecordingConsumer](_NODE_ID, consumer)
    assert_equal(consumer.consume_count, 1, "the value was revealed before the drop")
    _ = consumer^
    _ = reg^


# (e) unbound node_id -> raises before the store is reached.
def test_unbound_node_id_raises() raises:
    var store = _scripted_store()
    var probe = store.share()
    var reg = _registry(store^)

    assert_false(reg.has_binding(999), "node 999 has no binding")

    var consumer = _RecordingConsumer()
    with assert_raises(contains="no secret binding for node_id 999"):
        reg.reveal_for[_RecordingConsumer](999, consumer)

    assert_equal(probe.resolve_count(), 0, "an unbound node never reaches the store")
    assert_equal(consumer.consume_count, 0, "an unbound node never reaches the consumer")


# (f) from_bindings lifts every row of the store-less table.
def test_from_bindings_lifts_every_row() raises:
    var store = _scripted_store()
    store.put(_OTHER_REF, _OTHER_SECRET)
    var probe = store.share()

    var bindings = SecretBindings()
    bindings.bind(_NODE_ID, String(_NAME_HANDLE), String(_SECRET_REF))
    bindings.bind(_OTHER_NODE_ID, String(_OTHER_HANDLE), String(_OTHER_REF))
    var reg = _Registry.from_bindings(store^, bindings)

    assert_equal(reg.num_entries(), 2, "both rows lifted")
    assert_true(reg.has_binding(_NODE_ID), "row 1 is bound")
    assert_true(reg.has_binding(_OTHER_NODE_ID), "row 2 is bound")
    assert_false(reg.has_binding(999), "a node outside the table stays unbound")

    var consumer = _RecordingConsumer()
    reg.reveal_for[_RecordingConsumer](_OTHER_NODE_ID, consumer)
    _assert_seen(consumer, _OTHER_SECRET, "row 2 reveals its own ref")
    reg.reveal_for[_RecordingConsumer](_NODE_ID, consumer)
    _assert_seen(consumer, _SECRET, "row 1 reveals its own ref")
    assert_equal(probe.resolve_count(), 2, "one resolve per reveal")


# (g) into_store hands back the same store.
def test_into_store_returns_the_same_store() raises:
    var reg = _registry(_scripted_store())
    var consumer = _RecordingConsumer()
    reg.reveal_for[_RecordingConsumer](_NODE_ID, consumer)
    reg.reveal_for[_RecordingConsumer](_NODE_ID, consumer)

    var store = reg^.into_store()
    assert_equal(
        store.resolve_count(), 2, "the recovered store carries the registry's resolves"
    )
    var value = store.resolve(_SECRET_REF)
    assert_equal(
        len(value.revealed_bytes()),
        len(_SECRET.as_bytes()),
        "the recovered store still resolves the scripted ref",
    )


def main() raises:
    test_resolve_through_registry_reveals_scripted_value()
    test_every_reveal_resolves_and_sees_a_rotation()
    test_unresolvable_ref_raises_before_the_consumer()
    test_secret_wiped_at_registry_drop()
    test_unbound_node_id_raises()
    test_from_bindings_lifts_every_row()
    test_into_store_returns_the_same_store()
    print(
        "PASS test_secret_registry (resolve-through, resolve-on-demand"
        " across a rotation, store error propagates, wiped-at-exit, unbound node"
        " fail-fast, from_bindings, into_store)"
    )
