"""`SessionSecretStore`: where a session keeps the values of its credentials.

A `SecretStore` (the one-method trait of `secret_store`) over bytes held in
memory, one value per opaque `secret_ref`. `SessionCredentials` writes a
value here when a credential is sealed; a reader gets it back only through
`resolve`, which mints a zeroizing `SecretValue`, so the values reach a
consumer the way every `SecretStore` hands them out: through a
`SecretRegistry` reveal or `SecretCapability.open_connection_for`, with the
bindings of `SessionCredentials.secret_bindings`.

Every value is wiped (`zeroize_list`) when it is replaced, removed, or when
the last handle over the store is dropped. `share` gives a second handle over
the same values, which is what a reveal consumes (it takes its store by
value). A store is used from one thread at a time, as the session that owns
it is.
"""

from std.memory import ArcPointer

from crypto import zeroize_list
from secret_store import SecretStore, SecretValue


struct _StoreState(Movable, Deinitable):
    """The values, by `secret_ref`, and the number of resolves."""

    var refs: List[String]
    var values: List[List[UInt8]]
    var resolves: Int

    def __init__(out self):
        self.refs = List[String]()
        self.values = List[List[UInt8]]()
        self.resolves = 0

    def find(self, secret_ref: String) -> Int:
        for i in range(len(self.refs)):
            if self.refs[i] == secret_ref:
                return i
        return -1

    def __deinit__(deinit self):
        """Wipe every value before its memory is freed."""
        for i in range(len(self.values)):
            zeroize_list(self.values[i])


struct SessionSecretStore(SecretStore, Movable, Deinitable):
    """A `SecretStore` over values held in memory: `put` a value under a
    `secret_ref`, `resolve` it into a `SecretValue`. A value replaced, removed
    or dropped with the store is wiped first."""

    var _p: ArcPointer[_StoreState]

    def __init__(out self):
        """An empty store."""
        self._p = ArcPointer[_StoreState](_StoreState())

    def __init__(out self, *, var _share: ArcPointer[_StoreState]):
        """`share`'s constructor: a second handle over existing values."""
        self._p = _share^

    def share(self) -> SessionSecretStore:
        """A second handle over the same values. A reveal takes its store by
        value, so a session lends it one of these."""
        return SessionSecretStore(_share=ArcPointer[_StoreState](copy=self._p))

    def put(mut self, secret_ref: String, var value: List[UInt8]):
        """Hold `value` under `secret_ref`, wiping the value it replaces. The
        store owns `value` from here on."""
        var at = self._p[].find(secret_ref)
        if at >= 0:
            zeroize_list(self._p[].values[at])
            self._p[].values[at] = value^
            return
        self._p[].refs.append(secret_ref.copy())
        self._p[].values.append(value^)

    def remove(mut self, secret_ref: String):
        """Wipe and forget the value under `secret_ref`; nothing when there is
        none."""
        var at = self._p[].find(secret_ref)
        if at < 0:
            return
        zeroize_list(self._p[].values[at])
        _ = self._p[].refs.pop(at)
        _ = self._p[].values.pop(at)

    def holds(self, secret_ref: String) -> Bool:
        """Whether a value is held under `secret_ref`."""
        return self._p[].find(secret_ref) >= 0

    def equals(self, secret_ref: String, value: Span[UInt8, _]) -> Bool:
        """Whether the value under `secret_ref` is byte for byte `value`;
        False when there is none. Reads the value in place (no copy and no
        resolve) and compares every byte of equal-length values."""
        var at = self._p[].find(secret_ref)
        if at < 0:
            return False
        ref held = self._p[].values[at]
        if len(held) != len(value):
            return False
        # Every byte is compared, whatever the first difference.
        var diff = UInt8(0)
        for i in range(len(held)):
            diff |= held[i] ^ value[i]
        return diff == 0

    def resolve_count(self) -> Int:
        """How many times `resolve` was called on any handle of this store."""
        return self._p[].resolves

    def resolve(mut self, secret_ref: String) raises -> SecretValue:
        """The value under `secret_ref` as a fresh zeroizing `SecretValue`.

        Raises:
            Error naming the `secret_ref` (a credential name and a field, never
            a value) when no value is held under it.
        """
        self._p[].resolves += 1
        var at = self._p[].find(secret_ref)
        if at < 0:
            raise Error(
                String("SessionSecretStore: no value for ") + secret_ref
            )
        ref held = self._p[].values[at]
        return SecretValue(Span[UInt8, origin_of(held)](held))
