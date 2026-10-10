# =============================================================================
# komira_secret_registry/secret_registry.mojo: the per-execution
#   `node_id -> secret_ref` side table and the connector reveal seam.
# =============================================================================
#
# WHAT THIS IS. `SecretRegistry` is the per-execution side table that binds a
# query's secret-bearing nodes (`node_id`) to their OPAQUE `secret_ref` handles,
# and OWNS the capability (`Store`) that resolves those handles: a per-execution
# value, constructed at the SDK/engine boundary, threaded by value, consulted per
# secret-bearing node, dropped at execution exit.
#
# THE COMPOSED CAPABILITY (authorize, then audit, at resolve). The registry owns
# its `Store` by value as a MONOMORPH. The intended shape is a store that checks
# the caller's authorization and records an audit entry around an inner
# provider store, so the registry's `resolve(secret_ref)` runs both checks by
# construction, with no type erasure (no function pointer, no erased handle):
# the concrete composed type is the `Store` type parameter, both checks fire
# inside ONE `self._store.resolve` call, and the compiler sees the whole stack.
# A different composition (an unchecked provider, an audit-only stack) is a
# different `Store` monomorph; the registry code is identical.
#
# CONTAINER CHOICE. The registry holds its bindings in a plain VALUE
# `Slab[SecretRegistryEntry]` keyed by a linear `node_id` scan, not a `Dict` or
# an `OwnedPointer`-wrapped element, because:
#   (a) the registry is not a destroy-recreate struct: it is a per-execution
#       value constructed at the engine boundary, threaded by value and dropped
#       at execution exit, so allocator byte reuse across recreate cycles
#       cannot reinterpret a stale entry.
#   (b) `SecretRegistryEntry` is a FLAT value (an `Int` and two `String`s) with
#       no `SecretValue` field. The Slab moves elements, never reinterprets
#       their bytes, and there is no heap-inside-heap to leak. A `SecretValue`
#       is never stored in the Slab: that would defeat the "resolved on demand,
#       never cached" custody rule. Values are resolved per reveal and dropped
#       (zeroized) when the reveal exits.
#   (c) a plain `Slab` of flat entries avoids hashing and the extra
#       OwnedPointer indirection. node_ids are minted densely and the table is
#       tiny (one entry per secret-bearing source), so a linear scan is
#       negligible. A resolve cache, if one is ever added, MUST be
#       `Optional[OwnedPointer[SecretValue]]` (a bare `SecretValue` in a Slab
#       is the banned shape); none is shipped, since resolve-on-demand is the
#       tightest custody default.
#
# THE RAII WIPE GUARANTEE ("wiped at execution end"). The registry needs no
# explicit wipe call. On drop it frees the Slab (flat entries, no secret) and
# drops `_store`; any `SecretValue` minted on the reveal path is a LOCAL of
# `reveal_for` that drops (and its destructor ZEROIZES the inline buffer through
# an FFI memset the optimizer cannot remove) when that method exits, long before
# the registry itself drops. So the secret bytes live only for the single
# reveal, and since the registry has no `SecretValue` field there is nothing
# secret left to wipe when it drops.
#
# FAIL-FAST ON A MISSING BINDING (deliberately unlike komira_plan_expr's
# `FsBindings`). An unbound `node_id` RAISES: a secret-bearing node with no
# registry binding is a wiring error, never a silent local fallback. An
# unbound file-system node resolves to the LOCAL file system, a benign
# default; a MISSING SECRET has no benign default, so this raises.
#
# ENCAPSULATION: the public surface is `register` (an Int and two Strings in)
# and `reveal_for[Consumer]` (the reveal; a read-only `Span` reaches the
# consumer, no value comes out). No UnsafePointer crosses any boundary; the
# reveal `Span`'s origin is the reveal-local `SecretValue` (escape is a compile
# error); no wildcard origin. The registry OWNS its Slab and its `Store` by
# value.
# =============================================================================

from komira_collections.slab import Slab

from komira_secret_store.secret_store import SecretStore
from komira_secret_store.secret_value import SecretValue

from komira_secret_registry.secret_bindings import (
    SecretBindings,
    SecretRegistryEntry,
)

from .credential_consumer import CredentialConsumer


# =============================================================================
# §1 SecretRegistryEntry and SecretBindings live in
#   `komira_secret_registry.secret_bindings` and are imported above.
#
# Both are FLAT value types that import nothing, and the logical plan holds a
# `SecretBindings` field. Keeping them in the core packages keeps this package, and
# the secret-store stack below it, off the plan tier's dependency closure.
# =============================================================================


# =============================================================================
# §2 SecretRegistry[Store]: the per-execution side table and the reveal seam.
# =============================================================================
struct SecretRegistry[Store: SecretStore](Movable, Deinitable):
    """The per-execution `node_id -> secret_ref` side table that OWNS the
    resolve capability (`Store`) and exposes the connector reveal boundary. A
    per-execution VALUE (not destroy-recreate), constructed at the engine
    boundary, threaded by value, dropped at execution exit. Movable, not
    Copyable.

    `Store` is the capability owned by value, a MONOMORPH (no type erasure).
    The intended shape is a store that authorizes and then audits around an
    inner provider, so both checks fire inside the ONE `self._store.resolve`
    call the reveal makes.

    Bindings live in a plain VALUE `Slab[SecretRegistryEntry]` keyed by a
    linear `node_id` scan (see the module note). No `SecretValue` is ever
    stored: values are resolved per reveal and dropped (zeroized) when the
    reveal exits. On drop the registry frees the Slab (flat entries) and drops
    `_store`; RAII is the "wiped at execution end" guarantee (no explicit wipe
    call)."""

    var _entries: Slab[SecretRegistryEntry]
    var _store: Self.Store

    def __init__(out self, var store: Self.Store):
        """Construct an empty registry owning the resolve capability `store`.
        Bindings are added via `register`."""
        self._entries = Slab[SecretRegistryEntry].create_with_capacity(0)
        self._store = store^

    @staticmethod
    def from_bindings(
        var store: Self.Store, bindings: SecretBindings
    ) -> Self:
        """Lift a plan's STORE-LESS `SecretBindings` table into a
        `SecretRegistry[Store]` over the supplied `store`, at the materialize
        boundary. This is the seam that keeps the plan non-generic over the
        secret store: the plan carries only the flat `SecretBindings`; the
        concrete `Store` monomorph enters HERE (the `[Store]` generic at
        materialize), where the connector wraps both into a registry and drives
        `reveal_for`. Copies each flat `(node_id, name_handle, secret_ref)`
        binding into the registry's Slab (Strings and an Int; no `SecretValue`,
        resolve-on-demand)."""
        var reg = Self(store^)
        for i in range(bindings.num_entries()):
            var node_id = bindings.node_id_at(i)
            reg.register(
                node_id,
                bindings.name_handle_for(node_id),
                bindings.secret_ref_for(node_id),
            )
        return reg^

    def into_store(deinit self) -> Self.Store:
        """Recover the store (e.g. to verify an audit chain in a test, or to
        re-wrap it for a different execution). Drops the bindings Slab."""
        return self._store^

    def register(
        mut self, node_id: Int, var name_handle: String, var secret_ref: String
    ):
        """Bind `node_id -> (name_handle, secret_ref)`. Called at the engine/SDK
        boundary as each secret-bearing node is built. `node_id` MUST be the
        stable id set on the matching secret-bearing plan node. No value is
        stored, only the opaque handle that the store resolves on demand at
        reveal."""
        self._entries.append(
            SecretRegistryEntry(node_id, name_handle^, secret_ref^)
        )

    @always_inline
    def num_entries(self) -> Int:
        return len(self._entries)

    def _index_for(self, node_id: Int) -> Int:
        """Slab index of the entry for `node_id`, or -1 if unbound. Linear scan
        (the table is tiny: one entry per secret-bearing source). Mirrors
        `FsBindings._index_for`."""
        for i in range(len(self._entries)):
            if self._entries[i].secret_node_id == node_id:
                return i
        return -1

    def has_binding(self, node_id: Int) -> Bool:
        """True iff `node_id` has an explicit secret binding in this registry."""
        return self._index_for(node_id) >= 0

    # =========================================================================
    # reveal_for: THE CONNECTOR REVEAL SEAM.
    # =========================================================================
    def reveal_for[
        Consumer: CredentialConsumer
    ](mut self, node_id: Int, mut consumer: Consumer) raises:
        """The connector reveal boundary. For the secret bound to `node_id`:
          1. `_index_for(node_id)` gives the binding's `secret_ref` (an UNBOUND
             node RAISES: fail-closed, never a silent local fallback; a missing
             secret is a wiring error, unlike an unbound file-system node's
             benign local-fs default);
          2. `self._store.resolve(secret_ref)` gives a LOCAL `SecretValue`. A
             composed store's authorization check and audit record fire HERE,
             inside this ONE call: a deny RAISES before any value is read (the
             inner provider is never reached), and the audit record is
             appended on the resolve path;
          3. `value.revealed_bytes()` gives a scoped read-only `Span` whose
             origin is the LOCAL `value` (the sole reader);
          4. `consumer.consume(span)`: the connector opens its connection or
             signs its request (a test asserts the bytes). The `Span` is
             consumed entirely inside this call and is never returned from
             `reveal_for`.

        THE LIFETIME AND WIPE GUARANTEE. The `SecretValue` is a LOCAL of this
        method; the `Span` handed to `consume` is origin-bound to it, so the
        compiler forbids the consumer from escaping it. When this method exits,
        the LOCAL `value` drops and its destructor ZEROIZES the inline buffer
        (an FFI memset the optimizer cannot remove). So the secret bytes live
        only for this single reveal: there is no owned copy to leak and no
        `SecretValue` retained by the registry.

        RAISES on: an unbound `node_id` (fail-closed); a deny, an audit error
        or an unresolvable handle from the store (the store's own raise,
        propagated); a consumer failure (a bad connection string surfaces
        cleanly). On a deny no value is ever read (the check short-circuits
        inside `_store.resolve` before the inner provider)."""
        # (1) Resolve the binding to the opaque secret_ref. Unbound: fail-closed.
        var idx = self._index_for(node_id)
        if idx < 0:
            raise Error(
                String(
                    "SecretRegistry.reveal_for: no secret binding for node_id "
                )
                + String(node_id)
                + String(
                    " (a secret-bearing node must be registered before reveal —"
                    " fail-closed, never a silent local fallback)"
                )
            )
        # Copy the handle out of the borrowed entry so the borrow does not span
        # the mutating `_store.resolve` call below (the entry's `secret_ref` is
        # a flat String; this is a name copy, never a value copy).
        var secret_ref = self._entries[idx].secret_ref.copy()

        # (2) Resolve through the store: a composed store's checks fire inside
        # this ONE call. A deny, an unresolvable handle or an audit error RAISES
        # here; the LOCAL `value` is never bound and no secret is read.
        var value = self._store.resolve(secret_ref)

        # (3) + (4) The single reveal: take the scoped `Span` (origin = `value`,
        # the local) and hand it to the consumer entirely inside this method.
        # The `Span` cannot escape `consume` (the origin would escape, a compile
        # error). Nothing secret leaves this call.
        consumer.consume(value.revealed_bytes())

        # `value` drops HERE at method exit, and its destructor zeroizes the
        # inline buffer. RAII is the wipe; an explicit last use makes the drop
        # point unambiguous.
        _ = value^
