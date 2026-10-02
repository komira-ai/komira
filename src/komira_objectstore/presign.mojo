# =============================================================================
# komira_objectstore/presign.mojo — the CLOUD-NEUTRAL seam for
#   "hand the client a URL it can transfer against directly, without us."
# =============================================================================
#
# ★ WHY THIS TRAIT EXISTS AT ALL, in one paragraph. Everything else in this
# package moves bytes THROUGH us: `ConditionalWriteStore.get` returns a
# `List[UInt8]` the service allocated, and every caller that serves those bytes
# to an HTTP client pays for them twice — once into our address space, once out.
# For the workloads this codebase actually runs that is fine; for git-LFS it is
# not, because an LFS object is BY DEFINITION the file somebody decided was too
# big to put in git. A presigned URL inverts it: we spend a signature (some
# hashes and one RSA op, no I/O) and the client talks to the bucket directly.
# The service never sees the payload, so the payload cannot bound the service.
#
# ★ WHY IT IS A TRAIT AND NOT A GCS FUNCTION. A managed app deploys into the
# CUSTOMER's cloud, and "works on GCP" is not an answer. All three major
# object stores have this
# primitive and all three have a DIFFERENT one:
#
#   GCS    V4 signed URL   — GOOG4-RSA-SHA256 over a canonical request; the
#                            signature is an RSA op with the service account's
#                            private key, carried in `X-Goog-Signature`.
#   S3     presigned URL   — AWS4-HMAC-SHA256 over a canonical request; the
#                            signature is an HMAC chain over the secret key,
#                            carried in `X-Amz-Signature`.
#   Azure  service SAS     — HMAC-SHA256 over a FIXED-ORDER field list (there is
#                            no canonical request), base64, carried in `sig`.
#
# They differ in the signature primitive, in what is canonicalized, in how the
# expiry is expressed (S3/GCS: a DURATION in seconds from an issue time; Azure:
# an ABSOLUTE ISO-8601 `se=` instant), and — the one that reaches the caller —
# in whether the client must send extra headers for the transfer to be accepted
# at all. Azure's block-blob PUT requires `x-ms-blob-type: BlockBlob`; without
# it the PUT is refused no matter how good the signature is. That is why
# `PresignedUrl` carries `required_headers` rather than being just a string: a
# seam that returned only a URL would work on two clouds and silently fail on
# the third, which is the exact failure mode this trait exists to prevent.
#
# ★ WHAT THIS SEAM DELIBERATELY DOES NOT DO. It does not authorize. A signer
# hands out a capability for a key it was ASKED about; deciding whether the
# caller may have that key is the caller's job and must have happened already.
# For LFS that decision is made over the REPO's grant (an LFS oid is public to
# anyone who has ever cloned the repo, so it can never be the subject of the
# decision).
# Putting authorization behind this trait would put it behind a per-cloud
# implementation, which is precisely where a policy must never live.
#
# ENCAPSULATION (all satisfied)
#   * ZERO UnsafePointer in any signature; in/out are `String` / `Int` / owned
#     value structs.
#   * ZERO wildcard origins, ZERO `unsafe_from_address`, ZERO take_pointee.
# * heap-reuse N/A: no heap-owning element is stored in a byte-backed slab.
# =============================================================================


# -----------------------------------------------------------------------------
# The value types.
# -----------------------------------------------------------------------------


@fieldwise_init
struct PresignedHeader(ImplicitlyCopyable, Copyable, Movable, Deinitable):
    """One header the client MUST send with the presigned transfer.

    Not a suggestion and not a credential. These are headers the signature
    covers (or that the storage service requires structurally), so a transfer
    that omits one is refused by the storage service, not by us."""

    var name: String
    var value: String


struct PresignedUrl(Copyable, Movable, Deinitable):
    """A capability to perform ONE method against ONE object, until an instant.

    Field layout:
      var url: String                        — absolute, dial verbatim
      var method: String                     — the ONLY verb the URL authorizes
      var expires_unix_seconds: Int64        — when the capability dies
      var required_headers: List[PresignedHeader]

    ★ `method` is part of the value because on every one of the three clouds the
    verb is INSIDE the signature (GCS/S3 canonical request line 1; Azure's
    signed-permissions field). A `PresignedUrl` for a GET is not a PUT that
    somebody forgot to use — it cannot be turned into one."""

    var url: String
    var method: String
    var expires_unix_seconds: Int64
    var required_headers: List[PresignedHeader]

    def __init__(
        out self,
        var url: String,
        var method: String,
        expires_unix_seconds: Int64,
        var required_headers: List[PresignedHeader],
    ):
        self.url = url^
        self.method = method^
        self.expires_unix_seconds = expires_unix_seconds
        self.required_headers = required_headers^



# -----------------------------------------------------------------------------
# Bounds that are OURS, not the cloud's.
# -----------------------------------------------------------------------------

comptime PRESIGN_MAX_TTL_SECONDS: Int = 3600
"""★ THE CEILING THIS CODEBASE IMPOSES — one hour, and it is far below what any
of the three clouds allow.

GCS's own documented maximum is `604800` seconds / 7 days
(https://docs.cloud.google.com/storage/docs/authentication/canonical-requests —
"The longest expiration value is 604800 seconds (7 days)"). We do not want it.

A presigned URL is a BEARER CAPABILITY with no revocation: once minted, nothing
we can do stops it working until it expires. It will be written into a client's
process memory, its `~/.gitconfig`-adjacent transfer logs, a CI job's captured
stdout, and a proxy access log. A 7-day URL in a CI log is a 7-day unauthenticated
read of a customer's largest file. A TTL is the ONLY revocation mechanism a
signed URL has, so it should be as short as the transfer allows and no longer."""

comptime PRESIGN_MIN_TTL_SECONDS: Int = 1
"""A zero or negative TTL is a programming error, not a "already expired" URL —
minting one produces a capability that fails on arrival and looks like an outage.
Signers refuse it."""


def check_presign_ttl(ttl_seconds: Int) raises:
    """Refuse a TTL outside `[PRESIGN_MIN_TTL_SECONDS, PRESIGN_MAX_TTL_SECONDS]`.

    Every conformer calls this BEFORE signing. Clamping instead of raising was
    considered and rejected: a caller that asked for 24 hours and silently got 1
    would ship a client that retries forever against a URL it believes is still
    good, and the bug would surface as a flaky transfer rather than as a refused
    mint."""
    if ttl_seconds < PRESIGN_MIN_TTL_SECONDS:
        raise Error(
            "presign: refusing a TTL of "
            + String(ttl_seconds)
            + "s — a capability that is already dead is a bug, not a policy"
        )
    if ttl_seconds > PRESIGN_MAX_TTL_SECONDS:
        raise Error(
            "presign: refusing a TTL of "
            + String(ttl_seconds)
            + "s — this codebase caps presigned capabilities at "
            + String(PRESIGN_MAX_TTL_SECONDS)
            + "s because a signed URL cannot be revoked"
        )


# -----------------------------------------------------------------------------
# The trait.
# -----------------------------------------------------------------------------


trait ObjectUrlSigner(Movable, Deinitable):
    """Mint short-lived, method-scoped, direct-to-storage capabilities.

    ONE method per verb rather than one method taking a verb string, because the
    two verbs are not symmetric on any cloud: an upload capability may need
    required headers a download does not (Azure's `x-ms-blob-type`), and a
    signer that takes a `method: String` invites `presign("DELETE", key)` to
    compile. It should not compile.

    `key` is the store-relative object key, an OPAQUE object name: conformers
    sign it byte for byte and normalize nothing. A key in `Path`'s normal form
    (what `Path.parse(key).raw()` returns) names the same object a
    `ConditionalWriteStore` verb reaches through `Path.parse(key)`, so a caller
    holding such a key can reach either path. A key `Path.parse` would rewrite
    (a leading `/`, a `//`, a `.` or `..` segment) names a different object
    here than through the store. Conformers are responsible for mapping it into
    their own URL shape (bucket prefix, container, path style).

    Conformers in tree:
      * `komira_objectstore_gcs.GcsV4Signer` — GOOG4-RSA-SHA256
    """

    def presign_download(mut self, key: String, ttl_seconds: Int) raises -> PresignedUrl:
        """A capability to GET `key`, valid for `ttl_seconds`."""
        ...

    def presign_upload(mut self, key: String, ttl_seconds: Int) raises -> PresignedUrl:
        """A capability to PUT `key`, valid for `ttl_seconds`."""
        ...

    def signer_cloud(self) -> String:
        """A short lowercase tag for the cloud this signer targets (`gcs` / `s3`
        / `azure`). For diagnostics and for a response that wants to say which
        transfer adapter it handed out; never for dispatch."""
        ...


# -----------------------------------------------------------------------------
# The one piece of canonicalization that is SHARED across all three clouds.
# -----------------------------------------------------------------------------
#
# ★ WHY THIS LIVES IN THE NEUTRAL MODULE AND THE REST DOES NOT. GCS's V4, S3's
# presigned URL and Azure's SAS disagree about almost everything — what is
# canonicalized, in what order, with what signature primitive — so a shared
# "canonicalize a request" function would be three functions wearing one name.
# They agree on exactly one thing, and it is the thing that is easiest to get
# subtly wrong: WHICH BYTES MUST BE PERCENT-ENCODED.
#
# All three encode everything outside RFC 3986's unreserved set, per UTF-8 OCTET,
# with UPPERCASE hex. Getting the SET wrong is a silent wrong signature; getting
# the octet-vs-codepoint question wrong is a silent wrong signature (and is a
# real Mojo trap: a byte must never pass through `chr`). So the encoder is
# shared and vector-tested ONCE, through the GCS V4 signing vectors, and the
# per-cloud modules differ only in what they hand it.


@always_inline
def presign_is_unreserved(c: UInt8) -> Bool:
    """RFC 3986 unreserved: ALPHA / DIGIT / '-' / '.' / '_' / '~'."""
    return (
        (c >= UInt8(0x41) and c <= UInt8(0x5A))
        or (c >= UInt8(0x61) and c <= UInt8(0x7A))
        or (c >= UInt8(0x30) and c <= UInt8(0x39))
        or c == UInt8(0x2D)
        or c == UInt8(0x2E)
        or c == UInt8(0x5F)
        or c == UInt8(0x7E)
    )


@always_inline
def _presign_hex_upper_chr(v: Int) -> String:
    # SAFE: `chr` on a HEX DIGIT code point (0x30-0x39 / 0x41-0x46) over a 0-15
    # argument — the correct code-point-to-character use, never a stored byte.
    # NOT a member of the `chr(Int(byte))` decode class.
    if v < 10:
        return chr(0x30 + v)
    return chr(0x41 + v - 10)


def presign_percent_encode(input: String, encode_slash: Bool) -> String:
    """Percent-encode `input`, UPPERCASE hex, per UTF-8 OCTET.

    `encode_slash=False` for a PATH component (the separator must survive);
    `True` for a query name or value.

    ★ IT ITERATES BYTES, NOT CHARACTERS, and that is load-bearing: `é` (U+00E9)
    must become `%C3%A9` — TWO escapes for its two UTF-8 octets, not one escape
    for its codepoint. Google's "Query Parameter Encoding" conformance vector is
    the published falsifier for that, and the GCS V4 signing vectors assert it."""
    var out = String()
    var bs = input.as_bytes()
    for i in range(len(bs)):
        var c = bs[i]
        var keep = presign_is_unreserved(c)
        if c == UInt8(0x2F) and not encode_slash:
            keep = True
        if keep:
            # SAFE: `keep` is true only for an RFC 3986 UNRESERVED byte
            # (ALPHA/DIGIT/`-._~`) or `/` — every one of them < 0x80, where
            # `chr(Int(c))` is the IDENTITY. Every byte >= 0x80 takes the `%XX`
            # arm below (which is what makes `é` -> `%C3%A9`, the documented
            # per-OCTET contract). ⛔ DO NOT "fix" this line: it is already
            # byte-exact and the GCS v4 conformance vector depends on it.
            out += chr(Int(c))
        else:
            out += "%"
            out += _presign_hex_upper_chr(Int(c) >> 4)
            out += _presign_hex_upper_chr(Int(c) & 0xF)
    return out^
