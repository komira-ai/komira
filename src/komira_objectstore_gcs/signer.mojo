# =============================================================================
# komira_objectstore_gcs/signer.mojo
#   GcsV4Signer[C] — the komira_objectstore `ObjectUrlSigner` conformer for
#   GCS, over komira_gcp_core's V4 signing (GOOG4-RSA-SHA256).
# =============================================================================
#
# SHAPE.
#   * Bound to ONE bucket at construction; the trait's `key` is the object key
#     within that bucket, the same string a `ConditionalWriteStore` verb takes.
#     A caller holding a key cannot reach another bucket through it: the
#     bucket is the signer's field, and a bucket name holding `/` is refused.
#   * PATH STYLE: `<scheme>://<host>/<bucket>/<key>`. Virtual-hosted style is
#     equally signable (komira_gcp_core takes the authority and the path
#     separately) but needs a DNS-compatible bucket name, which a customer's
#     bucket need not be.
#   * The service account (its email and its PKCS#8 DER private key) is a
#     constructor parameter. Nothing here reads the environment, a key file or
#     a metadata server.
#
# THE CLOCK IS A SEAM. A V4 signature covers its own signing instant
# (X-Goog-Date and the credential scope's date), so the instant is an input
# to the signature. The signer reads it from a caller-supplied
# `GcsSigningClock`, ONCE per mint, and derives both the stamps and the
# reported `expires_unix_seconds` from that one reading. A fixed clock makes
# every mint byte-reproducible.
#
# BOUNDS. Every mint first applies komira_objectstore's TTL policy
# (`check_presign_ttl`, at most PRESIGN_MAX_TTL_SECONDS), which is far below
# GCS's own 7-day maximum that `gcs_v4_signed_url` enforces.
#
# ENCAPSULATION: no UnsafePointer, no wildcard origin; values only.
# =============================================================================

from komira_gcp_core import (
    GCS_V4_DEFAULT_HOST,
    GcsV4Header,
    GcsV4QueryParam,
    GcsV4ServiceAccount,
    gcs_v4_signed_url,
    gcs_v4_stamps_from_unix_seconds,
)
from komira_objectstore import (
    ObjectUrlSigner,
    PresignedHeader,
    PresignedUrl,
    check_presign_ttl,
)


comptime GCS_SIGNER_CLOUD: StaticString = "gcs"
"""The `signer_cloud()` tag of `GcsV4Signer`."""

comptime GCS_V4_DEFAULT_LOCATION: StaticString = "auto"
"""The credential-scope location GCS accepts for any bucket."""


trait GcsSigningClock(Movable, Deinitable):
    """The wall clock a `GcsV4Signer` signs at, in whole seconds since the
    Unix epoch (UTC). Supplied by the caller; the signer reads it once per
    mint."""

    def now_unix_seconds(mut self) raises -> Int64:
        ...


@fieldwise_init
struct FixedSigningClock(GcsSigningClock, ImplicitlyCopyable, Copyable, Movable):
    """A clock stopped at one instant: every mint signs at `unix_seconds`."""

    var unix_seconds: Int64

    def now_unix_seconds(mut self) raises -> Int64:
        return self.unix_seconds


def _check_bucket(bucket: String) raises:
    if len(bucket.as_bytes()) == 0:
        raise Error("gcs v4 signer: refusing an empty bucket name")
    if bucket.find("/") >= 0:
        raise Error(
            "gcs v4 signer: refusing the bucket name '"
            + bucket
            + "': a bucket name has no '/'"
        )


struct GcsV4Signer[C: GcsSigningClock](ObjectUrlSigner):
    """`ObjectUrlSigner` over one GCS bucket, signing V4 URLs at the instant
    its clock `C` reports.

    `presign_download` signs a GET and `presign_upload` a PUT; the verb is
    line 1 of the canonical request, so one cannot be used as the other.
    Neither returns a required header: a V4 signed PUT that signs no
    `content-type` accepts the body as sent. The only signed header is
    `host`."""

    var _account: GcsV4ServiceAccount
    var _bucket: String
    var _clock: Self.C
    var _location: String
    var _host: String
    var _scheme: String

    def __init__(
        out self,
        var account: GcsV4ServiceAccount,
        var bucket: String,
        var clock: Self.C,
        var location: String = String(GCS_V4_DEFAULT_LOCATION),
        var host: String = String(GCS_V4_DEFAULT_HOST),
        var scheme: String = String("https"),
    ) raises:
        """Refuses an empty bucket name or one holding `/`. `host` may carry a
        port (`host:port`, for an emulator); the URL keeps it and the
        signature covers the host without it."""
        _check_bucket(bucket)
        self._account = account^
        self._bucket = bucket^
        self._clock = clock^
        self._location = location^
        self._host = host^
        self._scheme = scheme^

    def signer_cloud(self) -> String:
        return String(GCS_SIGNER_CLOUD)

    def bucket(self) -> String:
        """The bucket every minted URL is scoped to."""
        return self._bucket

    def _presign(
        mut self, method: String, key: String, ttl_seconds: Int
    ) raises -> PresignedUrl:
        check_presign_ttl(ttl_seconds)
        if len(key.as_bytes()) == 0:
            raise Error("gcs v4 signer: refusing to sign an empty key")
        var stamps = gcs_v4_stamps_from_unix_seconds(
            self._clock.now_unix_seconds()
        )
        var url = gcs_v4_signed_url(
            self._scheme,
            method,
            self._host,
            String("/") + self._bucket + String("/") + key,
            List[GcsV4Header](),
            List[GcsV4QueryParam](),
            self._account,
            self._location,
            stamps,
            ttl_seconds,
        )
        return PresignedUrl(
            url^,
            method.copy(),
            stamps.unix_seconds + Int64(ttl_seconds),
            List[PresignedHeader](),
        )

    def presign_download(
        mut self, key: String, ttl_seconds: Int
    ) raises -> PresignedUrl:
        return self._presign(String("GET"), key, ttl_seconds)

    def presign_upload(
        mut self, key: String, ttl_seconds: Int
    ) raises -> PresignedUrl:
        return self._presign(String("PUT"), key, ttl_seconds)
