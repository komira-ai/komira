# =============================================================================
# komira_secret_registry.secret_bindings — the STORE-LESS bindings table the LOGICAL
#   PLAN carries (the engine-wiring side table for secrets).
# =============================================================================
#
# WHAT THIS IS. `SecretBindings` is the per-query
# `node_id -> (name_handle, secret_ref)` table WITHOUT the composed resolve
# capability (`Store`). It is the value the plan carrier holds (the secrets
# analog of the carrier's `FsBindings` field; the secrets registry is generic
# over `[Store: SecretStore]` and the carrier must NOT be — so the carrier holds
# only this NON-GENERIC bindings table, and the concrete composed
# `Store = Auditing(Authorizing(conformer))` is supplied at MATERIALIZE time,
# where the connector shim wraps these bindings + that store into a
# `SecretRegistry[Store]` and drives `reveal_for`).
#
# THE LOAD-BEARING SPLIT (why the carrier stays non-generic over the Store).
# `SecretRegistry[Store]` = bindings Slab + the composed `Store` by value. If
# the carrier held a `SecretRegistry[Store]` field it would have to be generic
# over `Store`, which explodes every carrier method's monomorphization.
# Instead the carrier holds THIS store-less `SecretBindings`, and
# `SecretRegistry.from_bindings(store, bindings)` (in `komira_secret_registry`)
# lifts the bindings into a `SecretRegistry[Store]` at the materialize
# boundary — the `[Store]` generic enters ONLY there (like `REG` for the FS
# cloud materialize), never on the carrier.
#
# CONTAINER. A plain VALUE `List[SecretRegistryEntry]` of FLAT entries (an
# `Int` + two flat `String`s; NO `SecretValue` field — values are resolved on
# demand at reveal, NEVER cached). Copyable (so it threads through both the
# move-based chain builders AND the borrow-based copying overloads via
# `.clone()`). Flat Strings + Int, no heap-inner-of-heap, no wildcard origin;
# the bindings is a per-query VALUE that moves WITH the plan (not a field on a
# destroy-recreate struct).
#
# ENCAPSULATION: `bind` (Int + two Strings in) + read-only probes
# (`num_entries` / `has_binding` / `name_handle_for` / `secret_ref_for`). ZERO
# UnsafePointer crosses any boundary; NO `SecretValue` is ever stored; no wildcard
# origin; no unsafe_from_address.
# =============================================================================

# ⭐ WHY THIS LIVES IN `komira_secret_registry`.plan` AND NOT IN `komira_secret_registry`.
# `PlanCarrier` — the UNIVERSAL read survivor every `ctx.read_*` returns —
# holds an `Optional[SecretBindings]` field. If these two flat POD structs
# lived in `komira_secret_registry`, that ONE field would put
# `komira_secret_registry` on the LOGICAL-PLAN tier's `-I` closure, and with it
# the WHOLE secret-store stack it deps on (secret stores, audit, authz, the
# database clients, JWKS, crypto, HTTP), for a LOGICAL PLAN that resolves no
# secret and calls no store.
#
# ⛔ AND NEITHER STRUCT NEEDS ANY OF IT. Both are FLAT PODs — an `Int` plus two
# `String`s, and a `List` of them. Their combined import list is EMPTY.
# ⛔ DO NOT MOVE EITHER STRUCT into `komira_secret_registry`, and do not add an
# import here: the whole value of this module is that it names nothing.
#
# The heavy half — `SecretRegistry[Store]`, `CredentialConsumer` and the
# `reveal_for` seam — lives in `komira_secret_registry`, which imports these
# two from here. This file is the STORE-LESS table the plan carries; that
# package is the store-COMPOSING registry the materialize boundary builds from
# it.


# =============================================================================
# §0 — SecretRegistryEntry — one `(node_id, name_handle, secret_ref)` binding.
#
# FLAT: an `Int` node_id + two flat `String`s (the catalog name handle
# the LLM emitted + the opaque `secret_ref` the store resolves). NO `SecretValue`
# field — values are resolved ON DEMAND at reveal, NEVER eagerly cached in the
# table.
# =============================================================================
struct SecretRegistryEntry(Copyable, Movable, Deinitable):
    """One `(node_id, name_handle, secret_ref)` binding in the registry side
    table. A FLAT value: an `Int` node_id + the catalog `name_handle` + the opaque
    `secret_ref` the composed store resolves. NO `SecretValue` field (values are
    resolved on demand, never eagerly cached). Copyable + Movable
    (flat Strings + an Int, no heap-inner-of-heap, no `SecretValue`). The
    `Copyable` conformance lets the store-less `SecretBindings` carrier (a
    `List[SecretRegistryEntry]`) thread through the carrier's borrow-based copying
    overloads (`.clone()`); the registry's Slab uses only the Movable contract."""

    var secret_node_id: Int
    var name_handle: String
    var secret_ref: String

    def __init__(
        out self, secret_node_id: Int, var name_handle: String, var secret_ref: String
    ):
        self.secret_node_id = secret_node_id
        self.name_handle = name_handle^
        self.secret_ref = secret_ref^


# =============================================================================
# §1 — SecretBindings — the store-less per-query `node_id -> secret_ref` table.
# =============================================================================
struct SecretBindings(Copyable, Movable, Deinitable):
    """The store-less per-query secret bindings table. Binds a
    query's secret-bearing nodes (`node_id`) to their `(name_handle, secret_ref)`
    pairs, but does NOT own the composed resolve capability — that `Store` is supplied
    at the materialize boundary, where the connector shim lifts these bindings into a
    `SecretRegistry[Store]` (`SecretRegistry.from_bindings`). This is what the
    plan carrier holds (the secrets analog of its `FsBindings` field) so the carrier
    stays NON-GENERIC over the secret store.

    Holds its bindings in a plain VALUE `List[SecretRegistryEntry]` of FLAT entries
    (an `Int` + two flat `String`s; NO `SecretValue` — resolve-on-demand).
    Copyable + Movable (flat entries, no heap-inner-of-heap, no
    wildcard origin); a per-query value that moves WITH the plan. Empty by default
    so a non-secret plan pays nothing."""

    var _entries: List[SecretRegistryEntry]

    def __init__(out self):
        """An empty bindings table (the default a non-secret DataFrame carries)."""
        self._entries = List[SecretRegistryEntry]()

    # `__copyinit__` is compiler-synthesized: `SecretRegistryEntry` is Copyable (flat
    # Strings + an Int), so the `List[SecretRegistryEntry]` deep-copies
    # cleanly — no heap-inner-of-heap to alias.

    def clone(self) -> Self:
        """Explicit deep copy (mirrors `FsBindings.clone`) — used by the DataFrame's
        borrow-based copying overloads (`__getitem__`)."""
        return self.copy()

    def bind(
        mut self, node_id: Int, var name_handle: String, var secret_ref: String
    ):
        """Bind `node_id -> (name_handle, secret_ref)`. Called by the SDK
        `ctx.with_secret(...)` builder as each
        secret-bearing node is minted. NO value is stored — only the opaque handle the
        composed store will resolve on demand at reveal."""
        self._entries.append(
            SecretRegistryEntry(node_id, name_handle^, secret_ref^)
        )

    def merge_from(mut self, var other: Self):
        """Absorb `other`'s `node_id -> (name_handle, secret_ref)` bindings into
        `self` — the secrets analog of `FsBindings.merge_from`, called by the SDK
        `.join` / `.cross_join` builders when two frames combine.

        A joined frame reads BOTH sides' sources, so it needs BOTH sides'
        credentials: dropping either half means one leg of `S3 ⋈ GCS` cannot
        resolve its secret at reveal time. `node_id`s are minted QUERY-UNIQUE (a
        monotonic counter on `EngineContext`, same invariant `FsBindings.merge_from`
        relies on), so entries are appended verbatim with no collision check.

        Consumes `other` by MOVING its entries out (no `.clone()`), so this stays
        non-raising and the FS-blind join builders' raise-signatures are unchanged.
        """
        for i in range(len(other._entries)):
            self._entries.append(other._entries[i].copy())
        other._entries.clear()

    @always_inline
    def num_entries(self) -> Int:
        return len(self._entries)

    def node_id_at(self, i: Int) -> Int:
        """The `node_id` of the `i`-th binding (for `SecretRegistry.from_bindings`'s
        index walk at the materialize boundary)."""
        return self._entries[i].secret_node_id

    def _index_for(self, node_id: Int) -> Int:
        """List index of the entry for `node_id`, or -1 if unbound. Linear scan (the
        table is tiny — one entry per secret-bearing node)."""
        for i in range(len(self._entries)):
            if self._entries[i].secret_node_id == node_id:
                return i
        return -1

    def has_binding(self, node_id: Int) -> Bool:
        """True iff `node_id` has an explicit secret binding in this table."""
        return self._index_for(node_id) >= 0

    def name_handle_for(self, node_id: Int) -> String:
        """The catalog `name_handle` bound to `node_id` (empty if unbound)."""
        var idx = self._index_for(node_id)
        if idx < 0:
            return String("")
        return self._entries[idx].name_handle.copy()

    def secret_ref_for(self, node_id: Int) -> String:
        """The opaque `secret_ref` bound to `node_id` (empty if unbound). The handle
        the composed store resolves at reveal — NEVER the value."""
        var idx = self._index_for(node_id)
        if idx < 0:
            return String("")
        return self._entries[idx].secret_ref.copy()
