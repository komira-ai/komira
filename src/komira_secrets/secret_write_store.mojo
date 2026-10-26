# =============================================================================
# komira_secrets/secret_write_store.mojo -- the `SecretWriteStore` adapter trait
#   (the WRITE half of the custody split) and the `InMemorySecretWriteStore`
#   test double.
# =============================================================================
#
# `SecretStore` (komira_secret_store) is the READ adapter: an opaque
# `secret_ref` handle in, a zeroizing `SecretValue` out. `SecretWriteStore` is
# its mirror: a SECRET VALUE in, an opaque `credential_ref` HANDLE out. The
# customer's secret store keeps the VALUE; the caller persists only the returned
# handle.
#
# `put(name, value)` takes the value as a flat `String` and returns the opaque
# handle. A live conformer turns the logical `name` into a durable resource
# handle in the customer's store; the in-memory double returns the `name`
# itself. Either way the caller never learns the value again from the handle:
# only the READ store can `resolve` it.
#
# Why a separate trait: keeping WRITE apart from READ preserves least
# privilege. Code that only reveals secrets depends on `SecretStore`; only
# provisioning code depends on `SecretWriteStore`. A conformer may implement one
# or both.
#
# The surface is value-typed: `String`s in and out, `raises` for an unreachable
# or rejecting store. No pointer type, no wildcard origin.
# =============================================================================

from std.memory import ArcPointer


# =============================================================================
# SecretWriteStore -- the pluggable WRITE adapter trait.
# =============================================================================
trait SecretWriteStore(Movable, Deinitable):
    """Write a secret `value` under a logical `name` INTO THE CUSTOMER SECRET
    STORE, returning the opaque `credential_ref` HANDLE the caller persists
    (never the value). Value in, handle out: the mirror of
    `SecretStore.resolve` (handle in, value out). An unreachable or rejecting
    store RAISES (fail fast and loud, never a silent drop that would lose the
    only copy of the secret). The returned handle is opaque and log-safe; the
    written value is never echoed in the handle, a log line or an error."""

    def put(mut self, name: String, value: String) raises -> String:
        ...


# =============================================================================
# InMemorySecretWriteStore -- an in-memory, spyable write double.
#
# Records every `put` (name -> value, plus a running `put_count`) behind an
# `ArcPointer`, so a `share()`d handle reads the AGGREGATE writes. A test asserts
# against a spy handle. It holds the written value as a plain `String` (a
# test/dev double: a live conformer keeps nothing at rest) and returns the `name`
# as the credential_ref.
# =============================================================================
struct _WriteRecord(Copyable, Movable, Deinitable):
    """One recorded `put(name, value)`."""

    var name: String
    var value: String

    def __init__(out self, var name: String, var value: String):
        self.name = name^
        self.value = value^


struct _WriteStoreState(Movable, Deinitable):
    """The double's interior: the ordered `put` log and a running `put_count`,
    behind an ArcPointer so both persist through `share()`."""

    var writes: List[_WriteRecord]
    var put_count: Int

    def __init__(out self):
        self.writes = List[_WriteRecord]()
        self.put_count = 0


struct InMemorySecretWriteStore(SecretWriteStore, Movable, Deinitable):
    """An in-memory, spyable `SecretWriteStore`. `put(name, value)` records the
    write and returns `name` as the opaque `credential_ref`. The log lives behind
    an `ArcPointer[_WriteStoreState]` so a `share()`d handle reads the
    AGGREGATE writes."""

    var _p: ArcPointer[_WriteStoreState]

    def __init__(out self):
        self._p = ArcPointer[_WriteStoreState](_WriteStoreState())

    def __init__(out self, *, var _share: ArcPointer[_WriteStoreState]):
        """Private ctor for `share()`: adopt an existing (copied) ArcPointer."""
        self._p = _share^

    def share(self) -> InMemorySecretWriteStore:
        """A SECOND handle over ONE `_WriteStoreState`, so a test reads the
        aggregate writes off any handle. Ref-counted shared ownership; a test
        double driven on one thread."""
        return InMemorySecretWriteStore(
            _share=ArcPointer[_WriteStoreState](copy=self._p)
        )

    def put(mut self, name: String, value: String) raises -> String:
        """Record the `put` and return `name` as the opaque `credential_ref`."""
        self._p[].put_count += 1
        self._p[].writes.append(_WriteRecord(name.copy(), value.copy()))
        return name.copy()

    def put_count(self) -> Int:
        """How many times `put` was called."""
        return self._p[].put_count

    def num_writes(self) -> Int:
        """How many writes are in the log."""
        return len(self._p[].writes)

    def value_for(self, name: String) -> String:
        """The last value written under `name` (empty if none)."""
        var out = String("")
        for i in range(len(self._p[].writes)):
            if self._p[].writes[i].name == name:
                out = self._p[].writes[i].value.copy()
        return out^

    def any_value_equals(self, needle: String) -> Bool:
        """True iff ANY recorded write's value equals `needle`."""
        for i in range(len(self._p[].writes)):
            if self._p[].writes[i].value == needle:
                return True
        return False
