# =============================================================================
# komira_crypto/hash.mojo — streaming Hash trait conformers via AWS-LC FFI
# =============================================================================
#
# Thin Movable wrappers over AWS-LC's EVP_MD_CTX_* opaque streaming context.
# The FFI conformer Sha2Hasher[OUTPUT_SIZE] in internal/asm/sha256_ffi.mojo
# provides the actual streaming implementation; callers use Sha256() /
# Sha384() / Sha512().
#
# Why a wrapper struct (not a `var Sha256 = Sha256Ffi` alias):
#   * Mojo trait conformance is checked structurally. Aliasing directly to
#     Sha2Hasher[32] (which is itself an alias) loses the ability to attach
#     Sha256-specific docstrings and to keep the trait conformance markers
#     in plain view.
#   * The wrapper carries the BLOCK_SIZE alias (64 for SHA-256, 128 for
#     SHA-384/512), which Sha2Hasher does not expose — it is part of the
#     `Hash` surface contract for any caller that reads it.
#
# Encapsulation invariants:
#   * ZERO UnsafePointer in any public method signature.
#   * ZERO wildcard origins on public surface.
#   * Inner FFI calls inherit the multi-line `# SAFETY:` discipline from
#     sha256_ffi.mojo.
# =============================================================================

from komira_crypto.traits import Hash
from komira_crypto.internal.asm.sha256_ffi import (
    Sha2Hasher,
    blake2b_256_oneshot,
    sha1_oneshot,
    sha2_oneshot,
)


# -----------------------------------------------------------------------------
# Sha256 — streaming SHA-256 conforming to `Hash` trait
# -----------------------------------------------------------------------------


struct Sha256(Hash, Movable, Deinitable):
    """Streaming SHA-256 (FIPS 180-4) backed by AWS-LC's EVP_MD_CTX.

    Trait conformer for `Hash` (declared in `traits.mojo`).

    Usage:

        var h = Sha256()
        h.update(message_bytes)
        var digest = InlineArray[UInt8, 32](fill=0)
        h.finalize_into(digest)

    `fork(self) -> Self` clones the streaming state via EVP_MD_CTX_copy_ex
    (load-bearing for TLS 1.3 transcript-hash snapshot flows).
    `finalize_into` is idempotent (works on a fork-clone internally).

    Constant-time: AWS-LC's SHA-256 implementation is data-oblivious.
    """

    comptime OUTPUT_SIZE: Int = 32
    comptime BLOCK_SIZE: Int = 64

    var _inner: Sha2Hasher[32]

    def __init__(out self):
        """Construct an empty SHA-256 streaming state."""
        self._inner = Sha2Hasher[32]()

    def update(mut self, data: Span[UInt8, _]):
        """Absorb `data` into the streaming state."""
        self._inner.update(data)

    def finalize_into[o: Origin[mut=True]](
        mut self,
        dst: Span[UInt8, o],
    ):
        """Emit the final digest into `dst` (>= 32 bytes). Idempotent."""
        self._inner.finalize_into(dst)

    def reset(mut self):
        """Reset the streaming state to empty (post-init state)."""
        self._inner.reset()

    def fork(self) -> Self:
        """Clone the streaming state."""
        return Self(_inner=self._inner.fork())

    def __init__(out self, *, var _inner: Sha2Hasher[32]):
        """Private ctor used by `fork()`."""
        self._inner = _inner^


# -----------------------------------------------------------------------------
# Sha384 — streaming SHA-384 conforming to `Hash` trait
# -----------------------------------------------------------------------------


struct Sha384(Hash, Movable, Deinitable):
    """Streaming SHA-384 (FIPS 180-4) backed by AWS-LC's EVP_MD_CTX.

    Trait conformer for `Hash`. Same surface as Sha256 with
    OUTPUT_SIZE=48 / BLOCK_SIZE=128.
    """

    comptime OUTPUT_SIZE: Int = 48
    comptime BLOCK_SIZE: Int = 128

    var _inner: Sha2Hasher[48]

    def __init__(out self):
        self._inner = Sha2Hasher[48]()

    def update(mut self, data: Span[UInt8, _]):
        self._inner.update(data)

    def finalize_into[o: Origin[mut=True]](
        mut self,
        dst: Span[UInt8, o],
    ):
        self._inner.finalize_into(dst)

    def reset(mut self):
        self._inner.reset()

    def fork(self) -> Self:
        return Self(_inner=self._inner.fork())

    def __init__(out self, *, var _inner: Sha2Hasher[48]):
        self._inner = _inner^


# -----------------------------------------------------------------------------
# Sha512 — streaming SHA-512 conforming to `Hash` trait
# -----------------------------------------------------------------------------


struct Sha512(Hash, Movable, Deinitable):
    """Streaming SHA-512 (FIPS 180-4) backed by AWS-LC's EVP_MD_CTX.

    Trait conformer for `Hash`. OUTPUT_SIZE=64 / BLOCK_SIZE=128.
    """

    comptime OUTPUT_SIZE: Int = 64
    comptime BLOCK_SIZE: Int = 128

    var _inner: Sha2Hasher[64]

    def __init__(out self):
        self._inner = Sha2Hasher[64]()

    def update(mut self, data: Span[UInt8, _]):
        self._inner.update(data)

    def finalize_into[o: Origin[mut=True]](
        mut self,
        dst: Span[UInt8, o],
    ):
        self._inner.finalize_into(dst)

    def reset(mut self):
        self._inner.reset()

    def fork(self) -> Self:
        return Self(_inner=self._inner.fork())

    def __init__(out self, *, var _inner: Sha2Hasher[64]):
        self._inner = _inner^


# -----------------------------------------------------------------------------
# Sha1 — streaming SHA-1, a WITNESS digest. Deliberately NOT a `Hash`.
# -----------------------------------------------------------------------------
#
# WHY IT EXISTS. Some registries publish SHA-1 as the content witness of what
# they store — npm's `dist.shasum` is the case that needs it — and comparing our
# bytes against that witness needs SHA-1 over a whole package tarball, which can
# be many megabytes. A SHA-1 sized for a ~60-byte WebSocket handshake key, or a
# query engine's scalar `sha1()`, does not fit. This one streams through
# AWS-LC's EVP_MD_CTX like its SHA-2 siblings, with no copy of the input.
#
# ⛔ WHY IT IS NOT A `Hash`. SHA-1 is collision-broken. `Hash` is the bound of
# `Hmac[H]`, `Hkdf[H]`, RSA-PSS and the TLS transcript; conforming would make
# every one of those instantiable over SHA-1, and the type system is the only
# reviewer that reads every call site. So `Sha1` has the same method surface as
# `Sha256` — `update` / `finalize_into` / `reset` / `fork` — and NO trait: a
# witness comparison can use it, a security construction cannot even be
# spelled over it. Making it a `Hash` is a one-word change, and a decision; it
# is not a cleanup.


struct Sha1(Movable, Deinitable):
    """Streaming SHA-1 (FIPS 180-4 §6.1) backed by AWS-LC's EVP_MD_CTX.

    A WITNESS digest (npm `dist.shasum`), not a security primitive — see the
    block comment above for why this is not a `Hash` conformer.

    Usage:

        var h = Sha1()
        h.update(chunk_a)
        h.update(chunk_b)
        var digest = InlineArray[UInt8, 20](fill=0)
        h.finalize_into(digest)

    `finalize_into` is idempotent (it finalizes a clone of the state), so a
    caller may read the digest and keep absorbing. `fork` clones the state.
    """

    comptime OUTPUT_SIZE: Int = 20
    comptime BLOCK_SIZE: Int = 64

    var _inner: Sha2Hasher[20]

    def __init__(out self):
        """Construct an empty SHA-1 streaming state."""
        self._inner = Sha2Hasher[20]()

    def update(mut self, data: Span[UInt8, _]):
        """Absorb `data` into the streaming state. No copy of `data` is made."""
        self._inner.update(data)

    def finalize_into[o: Origin[mut=True]](
        mut self,
        dst: Span[UInt8, o],
    ):
        """Emit the final digest into `dst` (>= 20 bytes). Idempotent."""
        self._inner.finalize_into(dst)

    def reset(mut self):
        """Reset the streaming state to empty (post-init state)."""
        self._inner.reset()

    def fork(self) -> Self:
        """Clone the streaming state."""
        return Self(_inner=self._inner.fork())

    def __init__(out self, *, var _inner: Sha2Hasher[20]):
        """Private ctor used by `fork()`."""
        self._inner = _inner^


def sha1(data: Span[UInt8, _]) -> Array[UInt8, 20]:
    """One-shot SHA-1 of `data` via AWS-LC's SHA1() — a WITNESS digest (see
    `Sha1`). Empty input yields the canonical empty-message digest, pinned
    with the rest of the FIPS 180 examples by `tests/test_sha1_kat.mojo`."""
    return sha1_oneshot(data)


# -----------------------------------------------------------------------------
# blake2b_256 — one-shot BLAKE2b-256. A REGISTRY-PROTOCOL digest.
# -----------------------------------------------------------------------------
#
# WHY IT EXISTS. The Python package index's legacy upload form carries
# `blake2_256_digest` beside `sha256_digest`; the index verifies every digest
# it is given against the uploaded file and keys its own storage on the
# BLAKE2b-256 one. `uv publish` sends both, and so does any client speaking
# the same upload form. There is no streaming form and no `Hash`
# conformance: a wheel is uploaded from one buffer, and a digest nobody
# composes into a MAC or a signature has no reason to be spellable as one.


def blake2b_256(data: Span[UInt8, _]) -> Array[UInt8, 32]:
    """One-shot BLAKE2b-256 (RFC 7693, unkeyed, 32-byte output) of `data` via
    AWS-LC's BLAKE2B256(). Pinned against RFC 7693 / reference vectors by
    `tests/test_blake2b_256_kat.mojo`."""
    return blake2b_256_oneshot(data)
