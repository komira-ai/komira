# =============================================================================
# komira_azure_blob/azure_sas.mojo — Azure Blob service SAS
#   as an `ObjectUrlSigner`.
# =============================================================================
#
# The third leg of the portability seam. Same trait as `GcsV4Signer` and
# `S3PresignSigner`, so a caller written against `ObjectUrlSigner` runs
# unchanged against an Azure storage account.
#
# =============================================================================
# ★ AZURE IS THE ONE THAT PROVES THE SEAM HAD TO BE A TRAIT
# =============================================================================
# GCS V4 and S3 presign are near-siblings: both build a CANONICAL REQUEST from
# the method, path, query and headers, hash it, and sign the hash. Azure does
# none of that. A service SAS's string-to-sign is a FIXED, POSITIONAL list of
# named fields joined by `\n` — the method never appears in it (permissions do,
# as letters), the query string never appears in it, and headers never appear in
# it. Verbatim, for `sv=2020-12-06` and later, Blob resources
# (https://learn.microsoft.com/en-us/rest/api/storageservices/create-service-sas):
#
#     StringToSign = signedPermissions + "\n" +
#                    signedStart + "\n" +
#                    signedExpiry + "\n" +
#                    canonicalizedResource + "\n" +
#                    signedIdentifier + "\n" +
#                    signedIP + "\n" +
#                    signedProtocol + "\n" +
#                    signedVersion + "\n" +
#                    signedResource + "\n" +
#                    signedSnapshotTime + "\n" +
#                    signedEncryptionScope + "\n" +
#                    rscc + "\n" + rscd + "\n" + rsce + "\n" + rscl + "\n" + rsct
#
# Four things follow that no amount of "make the GCS function generic" would
# have produced:
#
#   1. ★ EVERY OPTIONAL FIELD IS AN EMPTY STRING WITH ITS NEWLINE STILL THERE.
#      "If a field is optional and not provided as part of the request, specify
#      an empty string for that field. Be sure to include the newline character
#      (\n) after the empty string." SIXTEEN fields, and we populate five. Drop
#      one newline and every SAS 403s. There is no canonicalization step that
#      would catch it — the string is just wrong.
#   2. ★ EXPIRY IS AN ABSOLUTE ISO-8601 INSTANT (`se=2026-10-01T12:00:00Z`), not
#      a duration in seconds. GCS and S3 both take `<issue time> + <N seconds>`.
#      So `ObjectUrlSigner.presign_*` takes a TTL and this conformer converts;
#      a seam that had passed an absolute instant would have forced the other
#      two to convert instead, and their conversion is the lossy direction.
#   3. ★ THE VERB IS A PERMISSION LETTER IN A FIXED ORDER — `racwd` for a blob,
#      "Any combination of these permissions is acceptable, but the order of
#      permission letters must match". A download is `r`; an upload of a new
#      blob is `cw` (create + write), NOT `wc`. `wc` is a 403.
#   4. ★★ A SIGNED PUT ALSO NEEDS A CLIENT HEADER. Azure's Put Blob refuses a
#      block-blob write without `x-ms-blob-type: BlockBlob`, no matter how good
#      the SAS is. THAT is why `PresignedUrl` carries `required_headers` (a
#      git-LFS batch response, for one, renders them into its per-action
#      `header` object). A seam that returned only a URL would work on GCS and
#      S3 and fail on Azure, in production.
#
# =============================================================================
# ★ THE SIGNATURE, AND ITS ONE MATERIAL DIFFERENCE FROM `azure_signing.mojo`
# =============================================================================
# `HMAC-SHA256(base64-decode(account_key), UTF8(string_to_sign))`, base64, then
# percent-encoded into the `sig=` query parameter. The KEY IS BASE64 IN ITS
# STORED FORM and must be DECODED before use — the same rule
# `azure_signing.build_string_to_sign`'s Shared Key path follows. Signing the
# base64 TEXT instead of its bytes produces a well-formed signature that is
# always rejected, which is the least debuggable of the failure modes here.
#
# ⚠ NOT VECTOR-TESTED, AND MORE WEAKLY EVIDENCED THAN GCS. Microsoft publishes
# worked EXAMPLES (`service-sas-examples`) but no machine-readable vector set,
# and `azure_signing.mojo`'s own header records the same finding for Shared Key
# ("Azure publishes no equivalent vector suite"). This conformer is asserted
# STRUCTURALLY in `tests/test_azure_presign.mojo`: the
# sixteen-field shape (asserted as a NEWLINE COUNT, which is the failure mode),
# the permission-letter order, the absolute-expiry conversion, the required
# `x-ms-blob-type` on upload and its absence on download, and determinism under
# a fixed clock. Weaker than 29 published vectors, and said so.
#
# THE CLOCK. `AzureSasSigner[C]` reads its `AzureSasClock` once per mint and
# derives `st`, `se` and the reported `expires_unix_seconds` from that one
# reading, as `GcsV4Signer` does with its `GcsSigningClock`. A signer kept
# for hours mints each URL from the time it is asked, not the time it was
# built. `SystemAzureSasClock` is the production clock (komira_clock's wall
# clock); `FixedAzureSasClock` stops at one instant, for tests.
#
# ENCAPSULATION: ZERO UnsafePointer in any
# signature, ZERO wildcard origins, ZERO unsafe_from_address, ZERO take_pointee.
# The account key is decoded into a local `List[UInt8]`, used at the HMAC, and
# never logged or rendered into an error.
# =============================================================================

from komira_clock import now_unix_ms
from komira_crypto import hmac_sha256_string
from komira_datetime import Timestamp, format_rfc3339
from komira_encoding import base64_decode, base64_encode
from komira_objectstore.presign import (
    ObjectUrlSigner,
    PresignedHeader,
    PresignedUrl,
    check_presign_ttl,
    presign_percent_encode,
)

comptime AZURE_SAS_VERSION: StaticString = "2020-12-06"
"""`sv`. Pinned to the version whose string-to-sign this file implements — the
one that added `signedEncryptionScope`. ★ THE VERSION AND THE FIELD LIST ARE ONE
DECISION: bumping `sv` without adding whatever fields that version appended
produces a SAS that Azure parses under the new rules and rejects. Change both or
neither."""

comptime AZURE_SAS_RESOURCE_BLOB: StaticString = "b"
comptime AZURE_SAS_PROTOCOL_HTTPS: StaticString = "https"

comptime AZURE_SAS_PERM_READ: StaticString = "r"
comptime AZURE_SAS_PERM_CREATE_WRITE: StaticString = "cw"
"""`cw`, not `wc`. The blob permission order is `racwd` and "the order of
permission letters must match" — `wc` is a 403. Create AND write, because an LFS
upload writes a blob that does not exist yet and `w` alone does not cover the
create on every path shape."""

comptime AZURE_SAS_BLOB_TYPE_HEADER: StaticString = "x-ms-blob-type"
comptime AZURE_SAS_BLOB_TYPE_BLOCK: StaticString = "BlockBlob"

comptime AZURE_SAS_MAX_TTL_SECONDS: Int = 604800
"""Not an Azure-documented ceiling (a service SAS `se=` is an arbitrary future
instant), but the same 7-day figure GCS and S3 impose, applied here so all three
conformers refuse at the same magnitude. `PRESIGN_MAX_TTL_SECONDS` (3600) is
what actually binds."""


def azure_sas_iso8601_utc(unix_seconds: Int64) raises -> String:
    """`YYYY-MM-DDThh:mm:ssZ` — the form `st=` / `se=` take (komira_datetime's
    RFC 3339 writer, whole seconds).

    NOT the compact `YYYYMMDDTHHMMSSZ` that GCS and S3 use. Emitting the compact
    form here yields a SAS Azure rejects at parse, which is at least a LOUD
    failure — unlike most of the ways this file can be wrong."""
    return format_rfc3339(Timestamp(Int(unix_seconds), 0))


def azure_sas_canonicalized_resource(
    account: String, container: String, blob: String
) -> String:
    """`/blob/<account>/<container>/<blob>`.

    "It must include the service name … the storage account name, and the
    resource name, and it must be URL-DECODED." So the blob name goes in RAW —
    percent-encoding it here signs a resource whose name contains a literal
    `%2F`, which is a different blob."""
    return (
        String("/blob/")
        + account
        + String("/")
        + container
        + String("/")
        + blob
    )


def azure_sas_string_to_sign(
    permissions: String,
    start_iso: String,
    expiry_iso: String,
    canonicalized_resource: String,
    signed_version: String,
    signed_resource: String,
    signed_protocol: String,
) raises -> String:
    """The sixteen-field, positional string-to-sign for `sv=2020-12-06`+ blob.

    ★ THE FIELDS WE DO NOT USE ARE STILL THERE, AS EMPTY LINES: `signedIdentifier`
    (no stored access policy — see the revocation note on `AzureSasSigner`),
    `signedIP`, `signedSnapshotTime`, `signedEncryptionScope`, and the five
    response-header overrides. Sixteen fields means FIFTEEN newlines, and
    `tests/test_azure_presign.mojo` asserts that count directly, because a missing
    newline is invisible in a diff and fatal on the wire."""
    if len(permissions.as_bytes()) == 0:
        raise Error("azure sas: refusing to sign empty permissions")
    if len(expiry_iso.as_bytes()) == 0:
        raise Error("azure sas: refusing to sign without an expiry")
    # ★ WRITTEN AS "FIELD, THEN ITS TERMINATOR" — 16 fields, 15 terminators, the
    # last field UNTERMINATED. The first version of this function bundled the
    # empty fields' terminators together and emitted FOURTEEN newlines, i.e. 15
    # fields: `signedIP` was silently absent. Nothing about the resulting string
    # looks wrong. GATE 4 of `test_presign_portability.mojo` caught it by
    # COUNTING, which is the only assertion shape that can — which is also why
    # that gate exists rather than a spot-check of the populated fields.
    var s = String()
    s += permissions            # 1  signedPermissions
    s += "\n"
    s += start_iso              # 2  signedStart
    s += "\n"
    s += expiry_iso             # 3  signedExpiry
    s += "\n"
    s += canonicalized_resource  # 4  canonicalizedResource
    s += "\n"
    s += ""                     # 5  signedIdentifier      — no stored policy
    s += "\n"
    s += ""                     # 6  signedIP              — unrestricted
    s += "\n"
    s += signed_protocol        # 7  signedProtocol
    s += "\n"
    s += signed_version         # 8  signedVersion
    s += "\n"
    s += signed_resource        # 9  signedResource
    s += "\n"
    s += ""                     # 10 signedSnapshotTime
    s += "\n"
    s += ""                     # 11 signedEncryptionScope
    s += "\n"
    s += ""                     # 12 rscc  (Cache-Control override)
    s += "\n"
    s += ""                     # 13 rscd  (Content-Disposition override)
    s += "\n"
    s += ""                     # 14 rsce  (Content-Encoding override)
    s += "\n"
    s += ""                     # 15 rscl  (Content-Language override)
    s += "\n"
    s += ""                     # 16 rsct  (Content-Type override) — UNTERMINATED
    return s^


def azure_sas_signature(
    string_to_sign: String, account_key_base64: String
) raises -> String:
    """`base64(HMAC-SHA256(base64-decode(account_key), UTF8(string_to_sign)))`.

    ★ THE KEY IS DECODED FIRST. An Azure account key is stored base64; HMACing
    the base64 TEXT produces a well-formed signature that Azure always rejects,
    with no diagnostic that points at the cause."""
    var key = base64_decode(account_key_base64)
    if len(key) == 0:
        raise Error("azure sas: account key decoded to zero bytes")
    var mac = hmac_sha256_string(Span(key), string_to_sign)
    var bytes = List[UInt8]()
    for i in range(32):
        bytes.append(mac[i])
    return base64_encode(Span(bytes))


struct AzureSasResult(Copyable, Movable, Deinitable):
    """URL plus the string-to-sign, so a test can assert the field shape."""

    var url: String
    var string_to_sign: String
    var signature_base64: String

    def __init__(
        out self,
        var url: String,
        var string_to_sign: String,
        var signature_base64: String,
    ):
        self.url = url^
        self.string_to_sign = string_to_sign^
        self.signature_base64 = signature_base64^


def azure_blob_service_sas(
    account: String,
    container: String,
    blob: String,
    permissions: String,
    start_unix_seconds: Int64,
    expiry_unix_seconds: Int64,
    account_key_base64: String,
    host_suffix: String = String("blob.core.windows.net"),
) raises -> AzureSasResult:
    """Mint a blob service SAS URL. PURE COMPUTE — the instants are inputs."""
    if len(account.as_bytes()) == 0 or len(container.as_bytes()) == 0:
        raise Error("azure sas: account and container are required")
    if len(blob.as_bytes()) == 0:
        raise Error("azure sas: refusing to sign an empty blob name")
    if expiry_unix_seconds <= start_unix_seconds:
        raise Error("azure sas: expiry must be after start")

    var st = azure_sas_iso8601_utc(start_unix_seconds)
    var se = azure_sas_iso8601_utc(expiry_unix_seconds)
    var res = azure_sas_canonicalized_resource(account, container, blob)
    var sts = azure_sas_string_to_sign(
        permissions,
        st,
        se,
        res,
        String(AZURE_SAS_VERSION),
        String(AZURE_SAS_RESOURCE_BLOB),
        String(AZURE_SAS_PROTOCOL_HTTPS),
    )
    var sig = azure_sas_signature(sts, account_key_base64)
    # The query is a FIXED, DOCUMENTED set — not a sorted canonical query. Azure
    # does not canonicalize the query at all (it is absent from the
    # string-to-sign), so order here is cosmetic and matches the docs' example.
    var url = (
        String("https://")
        + account
        + String(".")
        + host_suffix
        + String("/")
        + container
        + String("/")
        + presign_percent_encode(blob, False)
        + String("?sp=")
        + presign_percent_encode(permissions, True)
        + String("&st=")
        + presign_percent_encode(st, True)
        + String("&se=")
        + presign_percent_encode(se, True)
        + String("&spr=")
        + String(AZURE_SAS_PROTOCOL_HTTPS)
        + String("&sv=")
        + String(AZURE_SAS_VERSION)
        + String("&sr=")
        + String(AZURE_SAS_RESOURCE_BLOB)
        + String("&sig=")
        + presign_percent_encode(sig, True)
    )
    return AzureSasResult(url^, sts^, sig.copy())


trait AzureSasClock(Movable, Deinitable):
    """The wall clock an `AzureSasSigner` signs at, in whole seconds since
    the Unix epoch (UTC). The signer reads it once per mint; `st` is that
    instant and `se` is it plus the TTL. The signer refuses an instant of 0
    or less (a clock that could not be read)."""

    def now_unix_seconds(mut self) -> Int:
        ...


@fieldwise_init
struct FixedAzureSasClock(AzureSasClock, ImplicitlyCopyable):
    """A clock stopped at one instant: every mint signs at `unix_seconds`."""

    var unix_seconds: Int

    def now_unix_seconds(mut self) -> Int:
        return self.unix_seconds


@fieldwise_init
struct SystemAzureSasClock(AzureSasClock, ImplicitlyCopyable):
    """The production clock: the process wall clock (komira_clock's
    `now_unix_ms`, `CLOCK_REALTIME`), truncated to whole seconds.

    Azure checks `st`/`se` against its own clock, so a deployed signer signs
    at this one. Two reads may go backwards if the host's time is stepped.
    If the host clock cannot be read it reports 0, and the signer refuses to
    mint at that instant. It reads no environment and holds no state."""

    def now_unix_seconds(mut self) -> Int:
        return Int(now_unix_ms() // 1000)


struct AzureSasSigner[C: AzureSasClock](ObjectUrlSigner):
    """`ObjectUrlSigner` over one Azure blob container, signing each SAS at
    the instant its clock `C` reports when the URL is minted.

    ⚠ REVOCATION, stated because Azure is the cloud where a better option EXISTS
    and this conformer does not take it. An ad-hoc service SAS (what this mints)
    can only be revoked by ROTATING THE ACCOUNT KEY, which breaks every other
    SAS and every Shared Key caller at the same time. A SAS bound to a STORED
    ACCESS POLICY (`signedIdentifier`) can be revoked individually by deleting
    the policy. We mint ad-hoc, and the mitigation is the TTL — the same
    mitigation GCS and S3 have no alternative to. If Azure becomes a real
    deployment target, a stored access policy per container is the upgrade, and
    it is a field in the string-to-sign that is currently an empty line."""

    var _account: String
    var _container: String
    var _account_key_base64: String
    var _host_suffix: String
    var _clock: Self.C

    def __init__(
        out self,
        var account: String,
        var container: String,
        var account_key_base64: String,
        var clock: Self.C,
        var host_suffix: String = String("blob.core.windows.net"),
    ):
        """Construction reads no clock. Each `presign_*` reads `clock`
        once; a production signer passes `SystemAzureSasClock()`."""
        self._account = account^
        self._container = container^
        self._account_key_base64 = account_key_base64^
        self._host_suffix = host_suffix^
        self._clock = clock^

    def signer_cloud(self) -> String:
        return String("azure")

    def _now(mut self) raises -> Int64:
        """One clock reading, refused when it is not a positive instant."""
        var now = self._clock.now_unix_seconds()
        if now <= 0:
            # komira_clock reports 0 when the host clock cannot be read; a
            # SAS whose window starts at the epoch is already expired.
            raise Error(
                "azure sas: refusing to sign at the non-positive instant "
                + String(now)
                + " (a clock that cannot be read reports 0)"
            )
        return Int64(now)

    def presign_download(
        mut self, key: String, ttl_seconds: Int
    ) raises -> PresignedUrl:
        check_presign_ttl(ttl_seconds)
        var now = self._now()
        var res = azure_blob_service_sas(
            self._account,
            self._container,
            key,
            String(AZURE_SAS_PERM_READ),
            now,
            now + Int64(ttl_seconds),
            self._account_key_base64,
            self._host_suffix,
        )
        return PresignedUrl(
            res.url.copy(),
            String("GET"),
            now + Int64(ttl_seconds),
            List[PresignedHeader](),
        )

    def presign_upload(
        mut self, key: String, ttl_seconds: Int
    ) raises -> PresignedUrl:
        """★ THE ONE CONFORMER THAT RETURNS A REQUIRED HEADER. Azure's Put Blob
        refuses a block-blob write without `x-ms-blob-type: BlockBlob`,
        regardless of the SAS. The caller sends it with the upload (a git-LFS
        batch response carries it in the per-action `header` member)."""
        check_presign_ttl(ttl_seconds)
        var now = self._now()
        var res = azure_blob_service_sas(
            self._account,
            self._container,
            key,
            String(AZURE_SAS_PERM_CREATE_WRITE),
            now,
            now + Int64(ttl_seconds),
            self._account_key_base64,
            self._host_suffix,
        )
        var hdrs = List[PresignedHeader]()
        hdrs.append(
            PresignedHeader(
                String(AZURE_SAS_BLOB_TYPE_HEADER),
                String(AZURE_SAS_BLOB_TYPE_BLOCK),
            )
        )
        return PresignedUrl(
            res.url.copy(),
            String("PUT"),
            now + Int64(ttl_seconds),
            hdrs^,
        )
