# =============================================================================
# src/kci_pkg_upload/legacy_upload.mojo — the PyPI "legacy" upload:
#   one multipart/form-data POST, built byte for byte as `uv publish` builds it,
#   and the classification of what the index answers.
# =============================================================================
#
# THE WIRE, MEASURED (uv publish against a loopback recorder,
# `tests/fidelity/capture_uv_publish.py`):
#
#   POST <upload path>
#   Content-Type: multipart/form-data; boundary=<16hex>-<16hex>-<16hex>-<16hex>
#   Accept: application/json;q=0.9, text/plain;q=0.8, text/html;q=0.7
#   Authorization: Basic <base64(user:password)>
#
#   --<boundary>\r\n
#   Content-Disposition: form-data; name="<field>"\r\n
#   \r\n
#   <value>\r\n
#   … one part per text field, in `legacy_upload_fields`' order …
#   --<boundary>\r\n
#   Content-Disposition: form-data; name="content"; filename="<file name>"\r\n
#   \r\n
#   <the file's bytes>\r\n
#   --<boundary>--\r\n
#
# ⚠ The file part carries NO Content-Type header, and no text part does either.
# ⚠ The body is sent with a Content-Length (not chunked); the transport adds it.
# ⚠ The Accept header matters: the index renders its refusal as JSON when JSON
#   is acceptable, and the refusal TEXT is how a duplicate, a burned file name
#   and a closed release window are told apart.
#
# ⭐ THE BOUNDARY IS DERIVED, NOT RANDOM. It has uv's shape (four 16-hex groups,
# 67 characters, so the body is exactly as long as uv's) and its value is a hash
# of the file's sha256. So a retry after an UNKNOWN sends the identical bytes,
# and a golden test can pin the whole request. The body is REFUSED (a local
# fault) if `--<boundary>` occurs inside any field value or the file itself —
# a multipart body that contained its own delimiter would be parsed as
# different fields than the ones sent.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from komira_crypto import blake2b_256, hex_lower, sha256
from komira_http_core.codec.types import HTTP_METHOD_POST

from .coordinate import PackageFile, normalize_distribution_name
from .core_metadata import (
    FormField,
    legacy_upload_fields,
    parse_core_metadata,
    parse_wheel_name,
)
from .outcome import (
    UPLOAD_AUTH_REFUSED,
    UPLOAD_BURNED,
    UPLOAD_CREATED,
    UPLOAD_DUPLICATE_REFUSED,
    UPLOAD_RATE_LIMITED,
    UPLOAD_REJECTED,
    UPLOAD_UNKNOWN,
    UPLOAD_WINDOW_CLOSED,
    UploadOutcome,
    excerpt_unless_echoes,
    upload_kind_name,
    withhold_if_echoes,
)
from .transport import PkgRequest
from .wire import append_str, bytes_contain, bytes_of


comptime LEGACY_UPLOAD_ACCEPT: String = (
    "application/json;q=0.9, text/plain;q=0.8, text/html;q=0.7"
)
"""The `Accept` header uv sends on the upload (measured)."""

comptime _BOUNDARY_DOMAIN: String = "kci_pkg_upload multipart boundary\n"


def legacy_upload_boundary(sha256_hex: String) -> String:
    """The multipart boundary for a file whose sha256 is `sha256_hex`: the
    lowercase hex of sha256(domain + sha256_hex), as four dash-joined 16-hex
    groups — uv's boundary SHAPE, deterministic in the file."""
    var seed = String(_BOUNDARY_DOMAIN) + sha256_hex
    var h = hex_lower(Span(sha256(seed.as_bytes())))
    return (
        String(h[byte=0:16])
        + String("-")
        + String(h[byte=16:32])
        + String("-")
        + String(h[byte=32:48])
        + String("-")
        + String(h[byte=48:64])
    )


def encode_legacy_multipart(
    fields: List[FormField],
    file_name: String,
    file_bytes: Span[UInt8, _],
    boundary: String,
) raises -> List[UInt8]:
    """The multipart/form-data body (see the file header for the exact bytes).

    RAISES when the delimiter occurs inside a value or the file, or when the
    file name could break its quoted `filename="…"` parameter."""
    var delim = String("--") + boundary
    var fb = file_name.as_bytes()
    for i in range(len(fb)):
        var c = fb[i]
        if c == UInt8(ord('"')) or c == UInt8(10) or c == UInt8(13):
            raise Error(
                String("kci_pkg_upload: file name '")
                + file_name
                + String("' cannot be carried in a quoted filename parameter")
            )
    var out = List[UInt8]()
    for i in range(len(fields)):
        if fields[i].value.find(delim) >= 0 or fields[i].name.find(String('"')) >= 0:
            raise Error(
                String("kci_pkg_upload: form field '")
                + fields[i].name
                + String("' contains the multipart delimiter or a quote")
            )
        append_str(out, delim)
        append_str(
            out,
            String('\r\nContent-Disposition: form-data; name="')
            + fields[i].name
            + String('"\r\n\r\n'),
        )
        append_str(out, fields[i].value)
        append_str(out, String("\r\n"))
    if bytes_contain(file_bytes, delim):
        raise Error(
            String("kci_pkg_upload: the file '")
            + file_name
            + String("' contains its own multipart delimiter; refusing to send")
        )
    append_str(out, delim)
    append_str(
        out,
        String('\r\nContent-Disposition: form-data; name="content"; filename="')
        + file_name
        + String('"\r\n\r\n'),
    )
    out.extend(file_bytes)  # the wheel: one bulk copy, not a per-byte loop
    append_str(out, String("\r\n"))
    append_str(out, delim)
    append_str(out, String("--\r\n"))
    return out^


def legacy_upload_form(f: PackageFile) raises -> List[FormField]:
    """The text fields for `f`, from its METADATA and digests of its bytes.
    RAISES when the coordinate's distribution or version is not the file
    name's — the ledger would key a file under a name it does not carry."""
    var wheel = parse_wheel_name(f.coordinate.file_name)
    if normalize_distribution_name(f.coordinate.distribution) != normalize_distribution_name(
        wheel.distribution
    ) or f.coordinate.version != wheel.version:
        raise Error(
            String("kci_pkg_upload: coordinate ")
            + f.coordinate.distribution
            + String(" ")
            + f.coordinate.version
            + String(" does not name the file '")
            + f.coordinate.file_name
            + String("'")
        )
    var meta = parse_core_metadata(f.upload_meta)
    var b2 = hex_lower(Span(blake2b_256(Span(f.bytes))))
    return legacy_upload_fields(
        meta, f.coordinate.file_name, f.identity.sha256_hex, b2
    )


def build_legacy_upload_request(
    host: String, path: String, f: PackageFile, authorization: String
) raises -> PkgRequest:
    """The complete upload request for `f` (every header and body byte except
    what the transport adds: Host, Content-Length). RAISES on a local fault —
    malformed METADATA, a Name/Version that disagrees with the file, a
    delimiter collision — before anything is sent."""
    var fields = legacy_upload_form(f)
    var boundary = legacy_upload_boundary(f.identity.sha256_hex)
    var body = encode_legacy_multipart(
        fields, f.coordinate.file_name, Span(f.bytes), boundary
    )
    var req = PkgRequest(HTTP_METHOD_POST, host.copy(), path.copy())
    req.with_header(
        String("Content-Type"),
        String("multipart/form-data; boundary=") + boundary,
    )
    req.with_header(String("Accept"), String(LEGACY_UPLOAD_ACCEPT))
    req.with_authorization(authorization)
    req.body = body^
    return req^


def _outcome(kind: Int, status: Int, body: List[UInt8], authorization: String) -> UploadOutcome:
    var detail = (
        upload_kind_name(kind)
        + String(" (HTTP ")
        + String(status)
        + String("): ")
        + excerpt_unless_echoes(body, authorization)
    )
    return UploadOutcome(kind, status, withhold_if_echoes(detail^, authorization))


def classify_warehouse_upload(
    status: Int, body: List[UInt8], authorization: String
) -> UploadOutcome:
    """What a warehouse (PyPI, TestPyPI) answer to the legacy upload means.

    The index answers every refusal with 400 and puts the REASON in the text
    (its own comment: changing the "File already exists" prefix breaks
    twine's --skip-existing), so the text decides:
      2xx                                   CREATED (⚠ also an identical dup)
      400 "File already exists"             DUPLICATE_REFUSED
      400 "…previously used by a file that has since been deleted…" /
          "…filename has already been used…" BURNED
      400 "Uploading new files to releases older than …"   WINDOW_CLOSED
      401 / 403                             AUTH_REFUSED
      409                                   DUPLICATE_REFUSED
      429                                   RATE_LIMITED
      5xx                                   UNKNOWN (the index may have stored it)
      anything else, 3xx included           REJECTED (an upload redirect is not
                                            followed: it would re-send the body
                                            and the credential elsewhere)"""
    if status >= 200 and status < 300:
        return _outcome(UPLOAD_CREATED, status, body, authorization)
    if status == 401 or status == 403:
        return _outcome(UPLOAD_AUTH_REFUSED, status, body, authorization)
    if status == 429:
        return _outcome(UPLOAD_RATE_LIMITED, status, body, authorization)
    if status == 409:
        return _outcome(UPLOAD_DUPLICATE_REFUSED, status, body, authorization)
    if status >= 500:
        return _outcome(UPLOAD_UNKNOWN, status, body, authorization)
    if status == 400:
        if bytes_contain(Span(body), String("File already exists")):
            return _outcome(UPLOAD_DUPLICATE_REFUSED, status, body, authorization)
        if bytes_contain(
            Span(body), String("previously used by a file that has since been deleted")
        ) or bytes_contain(Span(body), String("filename has already been used")):
            return _outcome(UPLOAD_BURNED, status, body, authorization)
        if bytes_contain(
            Span(body), String("Uploading new files to releases older than")
        ):
            return _outcome(UPLOAD_WINDOW_CLOSED, status, body, authorization)
    return _outcome(UPLOAD_REJECTED, status, body, authorization)


def unknown_after_transport_fault(message: String, authorization: String) -> UploadOutcome:
    """A transport raise on the POST: the client cannot tell whether bytes
    left, so the answer is UNKNOWN, never a raise."""
    return UploadOutcome(
        UPLOAD_UNKNOWN,
        0,
        withhold_if_echoes(
            String("UNKNOWN (transport fault; the upload may or may not have")
            + String(" been stored): ")
            + message,
            authorization,
        ),
    )
