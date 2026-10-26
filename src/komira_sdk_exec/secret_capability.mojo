# =============================================================================
# komira_sdk_exec/secret_capability.mojo — the SDK secret BINDING SURFACE + the
#   connector-shim that reveals at MATERIALIZE (Secrets Architecture RFC v3 §8.3 /
#   §8.4 / §8.5: engine-wiring Slice 2).
# =============================================================================
#
# WHAT THIS IS (the Slice-2 SDK binding surface). `SecretCapability` is the HANDLE
# generated code (the LLM-authored plan) holds for a secret-bearing node — it carries
# ONLY the per-execution `node_id`, NEVER the value, NEVER the `secret_ref`. It is
# minted by `ctx.with_secret(name_handle, secret_ref)` (`engine_context_secret.mojo`),
# which registers the `(node_id, name_handle, secret_ref)` binding into the
# DataFrame's STORE-LESS `SecretBindings` table and hands back this opaque handle.
#
# THE CONNECTOR SHIM AT MATERIALIZE (RFC §8.4). `open_connection_for[Store]` is the
# reveal boundary the engine drives AT materialize, AFTER the DataFrame's bindings +
# the concrete composed `Store = Auditing(Authorizing(conformer))` are both in hand:
#   1. lift the DataFrame's `SecretBindings` into a `SecretRegistry[Store]` over the
#      supplied `store` (`SecretRegistry.from_bindings` — the `[Store]` generic enters
#      HERE, at the materialize boundary, exactly like `REG` for the FS cloud
#      materialize; the DataFrame itself stays NON-GENERIC over the store);
#   2. call the Slice-1 `reveal_for[Consumer]` for THIS capability's `node_id` — the
#      composed store's RBAC-at-resolve gate (custody gate #1) + the audit emit
#      (custody gate #2) fire inside that ONE resolve; the value is revealed in-shim
#      via the origin-bound `Span` and handed to the consumer ENTIRELY inside the
#      reveal call (a real connector opens its DB connection here; a test asserts the
#      bytes), then wiped at the shim's exit — it NEVER escapes.
#
# WHY THE `[Store]` GENERIC IS ONLY HERE (the load-bearing non-generic-DataFrame rule).
# The Slice-1 `SecretRegistry` is generic over `[Store: SecretStore]`, but making the
# DataFrame / EngineContext generic over the store would explode every method's
# monomorphization (the comptime-fan-out hazard). So the DataFrame carries only the
# store-less `SecretBindings`, and `open_connection_for[Store]` is the ONE place the
# concrete composed store enters — generic at the materialize boundary, like the FS
# resolver. `SecretCapability` itself is a flat POD handle (an `Int` node_id), so
# nothing about the store leaks onto the handle the plan carries.
#
# REAL PER-EXECUTION node_id INTO THE AUDIT RECORD (RFC §8.5 — the Slice-2 advance).
# Slice 1 stamped the audit node_id explicitly via the `AuditingSecretStore`
# node_id-override ctor in the gate test; Slice 2 carries the SAME per-execution
# `node_id` on the capability, so the engine wires the real id into BOTH the registry
# binding AND the audit context (the composed `store` the caller supplies is built with
# the override ctor stamping this capability's id). The reveal then audits with the
# REAL node, not `AUDIT_NODE_ID_UNSET`.
#
# DEFERRED (Slice 2 scope boundary): the real DB driver in the shim (this slice's
# consumer is the caller-supplied `CredentialConsumer` — a test recorder or a future
# real connector); multi-secret-per-query reveal (this shim reveals ONE capability's
# node; a query with N secret-bearing nodes drives N reveals — additive); the `.join`
# merge of two DataFrames' `SecretBindings` (the FS-registry-style `merge_from`).
#
# ENCAPSULATION (rule): `SecretCapability` exposes only `node_id()` (an `Int`);
# `open_connection_for` takes a `read bindings`, a `var store`, and a `mut consumer`,
# reveals in-shim, returns nothing secret. ZERO UnsafePointer crosses any boundary; NO
# `SecretValue` is held on the capability or returned; no wildcard origin; no
# unsafe_from_address. The revealed `Span` is origin-bound to the shim-local
# `SecretValue` (escape = a compile error).
# =============================================================================

from komira_secret_registry.credential_consumer import CredentialConsumer
from komira_secret_registry.secret_bindings import SecretBindings
from komira_secret_registry.secret_registry import SecretRegistry

from komira_secret_store.secret_store import SecretStore


# =============================================================================
# §1 — SecretCapability — the opaque per-node secret HANDLE the plan carries.
# =============================================================================
struct SecretCapability(Copyable, Movable, Deinitable):
    """The handle generated code holds for a secret-bearing node (RFC §8.3, Slice 2).
    Carries ONLY the per-execution `node_id` — NEVER the value, NEVER the `secret_ref`
    (those live in the DataFrame's `SecretBindings` table, keyed by this id). Minted by
    `ctx.with_secret(...)`; consumed at materialize by `open_connection_for[Store]`.

    A flat POD handle (an `Int`): Copyable + Movable, gap6-clean (no heap, no
    `SecretValue`, no wildcard origin). The capability is what the plan carries through
    the chain; the store is NEVER on the handle (the non-generic-DataFrame rule)."""

    var _secret_node_id: Int

    def __init__(out self, secret_node_id: Int):
        self._secret_node_id = secret_node_id

    @always_inline
    def node_id(self) -> Int:
        """The per-execution `node_id` this capability binds (the key into the
        DataFrame's `SecretBindings` + the audit record's real node id)."""
        return self._secret_node_id

    # =========================================================================
    # open_connection_for — THE CONNECTOR SHIM AT MATERIALIZE (RFC §8.4).
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
        """The connector-shim reveal boundary, driven AT materialize.

        Driven for THIS capability's secret-bearing node (RFC §8.4):

          1. `SecretRegistry.from_bindings[Store](store, bindings)` — lift the
             DataFrame's STORE-LESS `bindings` into a `SecretRegistry[Store]` over the
             supplied composed `store` (the `[Store]` generic enters HERE — the
             materialize boundary, like `REG` for the FS cloud materialize; the
             DataFrame stayed non-generic);
          2. `reg.reveal_for[Consumer](self.node_id(), consumer)` — the Slice-1 reveal
             seam: `self._store.resolve(secret_ref)` runs the RBAC-at-resolve gate
             (custody gate #1 — a deny RAISES before the inner conformer is reached)
             AND emits the audit record (custody gate #2 — with the REAL per-execution
             node id the caller stamped into the composed store), then hands the
             value's scoped `revealed_bytes()` `Span` to `consumer.consume` ENTIRELY
             in-shim. A real connector opens its DB connection from those bytes; a test
             asserts them. The value is wiped at the reveal's exit — it NEVER escapes.

        RAISES on: an unbound `node_id` (fail-closed — a missing secret is a hard
        wiring error, NOT a silent fallback); an RBAC deny / audit error /
        unresolvable handle from the composed store (propagated — fail fast and loud);
        a consumer failure. On a deny RAISE the inner conformer is never reached and no
        value ever reaches the consumer.

        The `Store` + `Consumer` generics live ONLY on this materialize-boundary method
        — the capability + the DataFrame carry neither (the non-generic-DataFrame
        rule). The composed `store` is consumed (the registry owns it for the
        execution + wipes it on drop — RFC §8.5 'wiped at execution end')."""
        var reg = SecretRegistry[Store].from_bindings(store^, bindings)
        reg.reveal_for[Consumer](self._secret_node_id, consumer)
        # `reg` drops HERE -> frees the bindings Slab + drops the composed store. The
        # per-reveal SecretValue already wiped at `reveal_for`'s exit (RFC §8.5).
        _ = reg^
