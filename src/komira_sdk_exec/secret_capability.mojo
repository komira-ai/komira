# =============================================================================
# komira_sdk_exec/secret_capability.mojo — `SecretCapability`, an opaque handle
#   for a secret-bearing node, and `open_connection_for`, which reveals that
#   node's secret to a consumer.
# =============================================================================
#
# WHAT THIS IS. `SecretCapability` is a handle a caller holds for a
# secret-bearing node. It carries only the per-execution `node_id`: never the
# value and never the `secret_ref`. The `(node_id, name_handle, secret_ref)`
# bindings live in a store-less `SecretBindings` table (`komira_secret_registry`)
# that the caller keeps and passes in.
#
# THE REVEAL. `open_connection_for[Store, Consumer]` takes the bindings table, a
# concrete `Store` and a consumer. It:
#   1. lifts the bindings into a `SecretRegistry[Store]` over the supplied
#      `store` (`SecretRegistry.from_bindings`);
#   2. calls `SecretRegistry.reveal_for[Consumer]` for this capability's
#      `node_id`. The store's `resolve` runs once inside that call, so an
#      authorizing or auditing store wrapper fires there. The value is handed to
#      the consumer as a `Span` that is origin-bound to a local `SecretValue`,
#      entirely inside the call, and the value is wiped when the call exits.
#
# WHERE THE `[Store]` GENERIC LIVES. Only on `open_connection_for`. The bindings
# table and `SecretCapability` do not mention the store type, and
# `SecretCapability` is a flat handle (an `Int`), so a caller that holds
# capabilities or bindings is not generic over the store.
#
# AUDIT NODE ID. The capability carries the same `node_id` that keys the
# bindings. A caller that wants the audit record to name that node builds the
# `store` it passes in so that it stamps this capability's id.
#
# NOT COVERED. This file does not open a real connection: the consumer is
# whatever `CredentialConsumer` the caller supplies. One call reveals one
# capability's node; a caller with several secret-bearing nodes calls once per
# capability.
#
# ENCAPSULATION. `SecretCapability` exposes only `node_id()` (an `Int`).
# `open_connection_for` takes the bindings by `read`, the store by `var`, and the
# consumer by `mut`, and returns nothing. No `UnsafePointer` crosses any
# boundary, no `SecretValue` is held on the capability or returned, and there is
# no wildcard origin or `unsafe_from_address`. The revealed `Span` is
# origin-bound to the call-local `SecretValue`, so letting it escape is a
# compile error.
# =============================================================================

from komira_secret_registry.credential_consumer import CredentialConsumer
from komira_secret_registry.secret_bindings import SecretBindings
from komira_secret_registry.secret_registry import SecretRegistry

from komira_secret_store.secret_store import SecretStore


# =============================================================================
# §1 — SecretCapability: the opaque per-node secret handle.
# =============================================================================
struct SecretCapability(Copyable, Movable, Deinitable):
    """The handle a caller holds for a secret-bearing node. Carries only the
    per-execution `node_id`: never the value and never the `secret_ref`, which
    live in the `SecretBindings` table keyed by this id. `open_connection_for`
    reveals the node's secret.

    A flat handle (an `Int`): Copyable and Movable, with no heap, no
    `SecretValue` and no wildcard origin. The store type is never on the
    handle."""

    var _secret_node_id: Int

    def __init__(out self, secret_node_id: Int):
        self._secret_node_id = secret_node_id

    @always_inline
    def node_id(self) -> Int:
        """The per-execution `node_id` this capability binds: the key into the
        `SecretBindings` table and the node id an audited store would record."""
        return self._secret_node_id

    # =========================================================================
    # open_connection_for — reveal this node's secret to a consumer.
    # =========================================================================
    def open_connection_for[
        Store: SecretStore,
        Consumer: CredentialConsumer,
    ](
        self,
        bindings: SecretBindings,
        var store: Store,
        mut consumer: Consumer,
    ) raises:
        """Reveal the secret bound to this capability's node to `consumer`.

          1. `SecretRegistry.from_bindings[Store](store, bindings)` lifts the
             store-less `bindings` into a `SecretRegistry[Store]` over the
             supplied `store`.
          2. `reg.reveal_for[Consumer](self.node_id(), consumer)` resolves the
             binding's `secret_ref` through the store (one `resolve` call, so an
             authorizing or auditing wrapper runs there; a deny raises before
             the inner store is reached), then hands the value's scoped
             `revealed_bytes()` `Span` to `consumer.consume` entirely inside the
             call. The value is wiped when the reveal exits and never escapes.

        Duplicate bindings: if `bindings` holds more than one entry for this
        node id, the first binding wins. Both `SecretBindings` and
        `SecretRegistry` look an id up by a linear scan that returns the first
        match.

        RAISES on: an unbound `node_id` (fail-closed, with no fallback); an
        error from the store's `resolve` (a deny, an audit failure or an
        unresolvable handle), propagated unchanged; a consumer failure,
        propagated unchanged. On a store error the consumer is never called.

        The `Store` and `Consumer` generics live only on this method. `store` is
        consumed: the registry owns it for the call and drops it on return."""
        var reg = SecretRegistry[Store].from_bindings(store^, bindings)
        reg.reveal_for[Consumer](self._secret_node_id, consumer)
        # `reg` drops here, which frees the bindings Slab and drops the store.
        # The per-reveal SecretValue was already wiped at `reveal_for`'s exit.
        _ = reg^
