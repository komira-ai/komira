# =============================================================================
# komira_secret_store/secret_store.mojo — the `SecretStore` adapter trait + the
#   `StaticSecretStore` in-memory test double.
# =============================================================================
#
# The trait is a SEAM, not an implementation: a `String` handle in, a
# `SecretValue` out, `raises` on an unresolvable ref. It names no provider, no
# endpoint and no credential. Every PARTICULAR store — a remote secret service,
# the OS keychain — lives outside this package and conforms to
# the trait.
#
# `StaticSecretStore` lives beside the trait because a trait whose only
# conformers live elsewhere could not be tested here at all.
#
# `SecretStore` turns an opaque `secret_ref` (a handle) into a usable
# `SecretValue` BY ASKING THE SECRET STORE. Handle in, value out.
#
# THE ADAPTER IS AN INTEGRATION LAYER, NOT CRYPTO: it does not decrypt, unwrap,
# or hold keys. The secret store hands it a plaintext value over an
# authenticated channel; the conformer copies that plaintext STRAIGHT into the
# zeroizing `SecretValue` and returns it — no intermediate at-rest copy, no
# `String` that outlives the wipe.
#
# CUSTODY / ENCAPSULATION: the seam surface is value-typed — a `String`
# (secret_ref, a NAME) in, a `SecretValue` (zeroizing) out, `raises` for an
# unknown / unresolvable ref or an unreachable store. ZERO UnsafePointer
# crosses the boundary; no wildcard origin; no unsafe_from_address. The resolved
# `SecretValue` is move-only (NOT Copyable) — a single owner threads it to the
# point of use, then it drops + wipes.
# =============================================================================

from std.memory import ArcPointer

from komira_secret_store.secret_value import SecretValue


# =============================================================================
# §0 — SecretStore — the pluggable ADAPTER trait.
# =============================================================================
trait SecretStore(Movable, Deinitable):
    """Resolve an opaque `secret_ref` (a handle) to its value BY ASKING THE
    SECRET STORE. Handle in, value out. An unknown / unresolvable ref —
    or an unreachable store — RAISES (the resolver surfaces a clean
    `status=failed` / job failure; fail fast and loud, never a silent stale
    value). No UnsafePointer crosses the boundary. The resolved value is
    a zeroizing, redacted-`Display` `SecretValue` (never logged, never in an
    error)."""

    def resolve(mut self, secret_ref: String) raises -> SecretValue:
        ...


# =============================================================================
# §1 — StaticSecretStore — an in-memory, scripted store (the test double).
#
# The conformer double lets us test the seam without a live secret store.
# Scripts `secret_ref -> bytes`, records a
# `resolve_count` (the resolution proof), and supports `share()` so a test reads
# the aggregate count off any handle.
#
# THE STORE DOUBLE HOLDS RAW BYTES, NOT `SecretValue` (deliberate): a
# `SecretValue` is move-only + zeroizes on drop, so it cannot live in a `Dict`
# that gets read repeatedly. The double therefore holds the scripted plaintext as
# `List[UInt8]` and MINTS a fresh zeroizing `SecretValue` from it on every
# `resolve` — exactly as a live conformer mints a fresh value from each store
# fetch. This is a TEST DOUBLE; a live conformer never holds the plaintext at
# rest like this (it fetches per-resolve from the secret store).
# =============================================================================
struct _StaticStoreState(Movable):
    """The static store's interior: a `secret_ref -> plaintext-bytes` map + a
    running `resolve_count`, behind an ArcPointer so the count + the script
    persist through `share()`. A Dict of flat `List[UInt8]` values + an Int;
    no wildcard-origin pointer, no byte-slab."""

    var scripted: Dict[String, List[UInt8]]
    var resolve_count: Int

    def __init__(out self):
        self.scripted = Dict[String, List[UInt8]]()
        self.resolve_count = 0


struct StaticSecretStore(SecretStore, Movable):
    """An in-memory `secret_ref -> bytes` `SecretStore`. The TEST DOUBLE (proves
    the resolve seam without a live store — a known ref resolves to its scripted
    value; an unknown ref RAISES; a rotated script makes the SAME ref resolve to
    the NEW value, the stable-handle property). Records a `resolve_count`.

    The map lives behind an `ArcPointer[_StaticStoreState]` so a `share()`d
    handle reads the AGGREGATE resolve count (the seam-mock interior-mutation
    shape)."""

    var _p: ArcPointer[_StaticStoreState]

    def __init__(out self):
        self._p = ArcPointer[_StaticStoreState](_StaticStoreState())

    def __init__(out self, *, var _share: ArcPointer[_StaticStoreState]):
        """Private ctor for `share()` — adopt an existing (copied) ArcPointer."""
        self._p = _share^

    def share(self) -> StaticSecretStore:
        """A SECOND handle over ONE `_StaticStoreState` (so a test reads the
        aggregate resolve count off any handle). SAFETY: ArcPointer ref-counted
        shared ownership; a TEST DOUBLE driven on ONE thread (NOT concurrent
        state under a parallelize barrier)."""
        return StaticSecretStore(
            _share=ArcPointer[_StaticStoreState](copy=self._p)
        )

    def put(mut self, secret_ref: String, value: String):
        """Script a `secret_ref -> value` mapping (test setup). The value is held
        as raw bytes; `resolve` mints a fresh zeroizing `SecretValue` from it.
        Re-`put`ting the SAME ref overwrites — rotation: after the
        secret store rotates, the same `secret_ref` resolves to the NEW value."""
        var bytes = List[UInt8]()
        var src = value.as_bytes()
        for i in range(len(src)):
            bytes.append(src[i])
        self._p[].scripted[secret_ref] = bytes^

    def remove(mut self, secret_ref: String) raises:
        """Delete a scripted entry — models the owner deleting the secret from
        the store; the next `resolve(secret_ref)` then RAISES."""
        if self._p[].scripted.__contains__(secret_ref):
            _ = self._p[].scripted.pop(secret_ref)

    def resolve_count(self) -> Int:
        """How many times `resolve` was called (the resolution proof)."""
        return self._p[].resolve_count

    def resolve(mut self, secret_ref: String) raises -> SecretValue:
        """Look up the scripted value for `secret_ref` + bump the resolve count,
        minting a FRESH zeroizing `SecretValue` from the scripted bytes. An
        unknown / removed ref RAISES (the unresolvable-ref contract — fail fast
        and loud)."""
        self._p[].resolve_count += 1
        if not self._p[].scripted.__contains__(secret_ref):
            raise Error(
                String("SecretStore: no secret for secret_ref ") + secret_ref
            )
        ref bytes = self._p[].scripted[secret_ref]
        return SecretValue(Span[UInt8, origin_of(bytes)](bytes))
