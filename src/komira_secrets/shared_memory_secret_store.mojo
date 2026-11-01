# =============================================================================
# komira_secrets/shared_memory_secret_store.mojo -- a process-lifetime in-memory
#   store that implements BOTH `SecretWriteStore` (put) and `SecretStore`
#   (resolve) over ONE shared state.
# =============================================================================
#
# A value WRITTEN through one handle is READABLE through another within the same
# process. The two single-direction doubles cannot do that:
# `InMemorySecretWriteStore` has no `resolve`, and `StaticSecretStore` has no
# `put`. `SharedMemorySecretStore` is one store, held for the process lifetime,
# whose `share()`d handles all see the same `name -> bytes` map.
#
# This is a dev and single-process store, NOT durable: its contents are lost on
# restart and are not shared across processes. A deployment that needs durable
# secrets wires a store conformer for a real secret service instead.
#
# The surface is value-typed: a `String` name and `String` value in on `put`; a
# name in and a zeroizing move-only `SecretValue` out on `resolve`. The store
# retains the plaintext as raw `List[UInt8]` bytes (a dev double only) and mints
# a FRESH `SecretValue` on every `resolve`. No pointer type crosses any
# boundary; no wildcard origin; no `unsafe_from_address`.
# =============================================================================

from std.memory import ArcPointer

from komira_secret_store import SecretStore, SecretValue

from komira_secrets.secret_write_store import SecretWriteStore


struct _SharedSecretState(Movable, Deinitable):
    """The shared interior: a `name -> plaintext-bytes` map plus `put_count` and
    `resolve_count`, behind an ArcPointer so every `share()`d handle reads and
    writes ONE state."""

    var scripted: Dict[String, List[UInt8]]
    var put_count: Int
    var resolve_count: Int

    def __init__(out self):
        self.scripted = Dict[String, List[UInt8]]()
        self.put_count = 0
        self.resolve_count = 0


struct SharedMemorySecretStore(
    SecretStore, SecretWriteStore, Movable, Deinitable
):
    """A process-lifetime in-memory `SecretStore` + `SecretWriteStore`. A value
    written via `put(name, value)` is readable via `resolve(name)` on this handle
    or any `share()`d one."""

    var _p: ArcPointer[_SharedSecretState]

    def __init__(out self):
        self._p = ArcPointer[_SharedSecretState](_SharedSecretState())

    def __init__(out self, *, var _share: ArcPointer[_SharedSecretState]):
        """Private ctor for `share()`: adopt an existing (copied) ArcPointer."""
        self._p = _share^

    def share(self) -> SharedMemorySecretStore:
        """A SECOND handle over ONE `_SharedSecretState`. Ref-counted shared
        ownership; not for concurrent use from several threads."""
        return SharedMemorySecretStore(
            _share=ArcPointer[_SharedSecretState](copy=self._p)
        )

    # ---- SecretWriteStore ----
    def put(mut self, name: String, value: String) raises -> String:
        """Write `value` under `name` and return `name` as the opaque
        `credential_ref`. Overwrites the same name (a rotation)."""
        self._p[].put_count += 1
        var bytes = List[UInt8]()
        var src = value.as_bytes()
        for i in range(len(src)):
            bytes.append(src[i])
        self._p[].scripted[name] = bytes^
        return name.copy()

    # ---- SecretStore ----
    def resolve(mut self, secret_ref: String) raises -> SecretValue:
        """Resolve `secret_ref` (a name) to its value, minting a FRESH zeroizing
        `SecretValue` from the stored bytes. An unknown or never-written ref
        RAISES, never a silent stale or empty value."""
        self._p[].resolve_count += 1
        if not self._p[].scripted.__contains__(secret_ref):
            raise Error(
                String("SharedMemorySecretStore: no secret for ") + secret_ref
            )
        ref bytes = self._p[].scripted[secret_ref]
        return SecretValue(Span[UInt8, origin_of(bytes)](bytes))

    def has(self, secret_ref: String) -> Bool:
        """True iff a value was written under `secret_ref` (a non-raising
        probe)."""
        return self._p[].scripted.__contains__(secret_ref)

    def put_count(self) -> Int:
        """How many times `put` was called."""
        return self._p[].put_count

    def resolve_count(self) -> Int:
        """How many times `resolve` was called."""
        return self._p[].resolve_count
