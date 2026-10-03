# =============================================================================
# komira_aws_core/s3_wire.mojo -- the S3 header values no model states
# =============================================================================
#
# Everything else about S3's wire form comes from the service model and the
# endpoint ruleset. These do not:
#
#   - `s3_copy_source`: the `x-amz-copy-source` value of CopyObject and
#     UploadPartCopy. The model types it as a plain string; botocore builds
#     it in `_quote_source_header_from_dict` (botocore/handlers.py):
#     `<bucket>/<key>`, or `<access point ARN>/object/<key>`, percent-encoded
#     with '/' kept, then `?versionId=<id>` appended as given.
#   - `s3_content_range_total`: the complete length a `Content-Range`
#     response header states (RFC 9110 section 14.4), which a ranged
#     GetObject needs to learn the object's size.
#   - `s3_apply_request_checksum`: the request checksum current AWS SDKs
#     send by default on an operation whose model has an
#     `httpChecksum.requestAlgorithmMember` (PutObject, UploadPart): the
#     algorithm header, `CRC32` when the caller chose none, and
#     `x-amz-checksum-crc32`, the base64 of the body's CRC-32, big-endian.
#     botocore does this in `resolve_request_checksum_algorithm` and
#     `apply_request_checksum` (botocore/httpchecksum.py) under its default
#     `request_checksum_calculation = when_supported`, and does nothing when
#     the caller already set an `x-amz-checksum-*` header. botocore sends
#     the checksum as a header over http and, for a streaming body over
#     https, as an aws-chunked trailer; this sends it as a header always,
#     which S3 accepts on both.
# =============================================================================

from komira_encoding import base64_encode

from ._regex import Regex
from ._text import ascii_lower, sub, trim
from .aws_request import AwsRequest
from .sigv4 import uri_encode


# botocore's VALID_S3_ARN (botocore/handlers.py, at the release
# //third_party/botocore pins; re-check both when the pin moves): an access
# point ARN, or an Outposts access point ARN. A bucket matching either names an access point,
# whose objects live under `object/`.
comptime _ACCESS_POINT_ARN = (
    "^arn:(aws).*:(s3|s3-object-lambda):[a-z\\-0-9]*:[0-9]{12}:accesspoint[/:]"
    "[a-zA-Z0-9\\-.]{1,63}$"
)
comptime _OUTPOST_ARN = (
    "^arn:(aws).*:s3-outposts:[a-z\\-0-9]+:[0-9]{12}:outpost[/:]"
    "[a-zA-Z0-9\\-]{1,63}[/:]accesspoint[/:][a-zA-Z0-9\\-]{1,63}$"
)


def s3_copy_source(
    bucket: String, key: String, version_id: Optional[String] = None
) raises -> String:
    """The `x-amz-copy-source` value naming object `key` of `bucket` (a
    bucket name or an access point ARN), at `version_id` when given. Every
    byte but the RFC 3986 unreserved set and '/' is percent-encoded, as
    UTF-8; the version id is appended unencoded."""
    var path: String
    # Both patterns start `^arn:`; a plain bucket name skips compiling them.
    if bucket.startswith("arn:") and (
        Regex(_ACCESS_POINT_ARN).matches(bucket)
        or Regex(_OUTPOST_ARN).matches(bucket)
    ):
        path = bucket + "/object/" + key
    else:
        path = bucket + "/" + key
    var out = uri_encode(path, keep_slash=True)
    if version_id:
        out += "?versionId=" + version_id.value()
    return out^


def _digits(s: String, what: String, header: String) raises -> Int:
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > 18:
        raise Error(
            "Content-Range '" + header + "': " + what + " is not a byte count"
        )
    var n = 0
    for i in range(len(b)):
        if b[i] < 0x30 or b[i] > 0x39:
            raise Error(
                "Content-Range '" + header + "': " + what + " is not a byte count"
            )
        n = n * 10 + Int(b[i] - 0x30)
    return n


def s3_content_range_total(value: String) raises -> Optional[Int]:
    """The complete length of a `Content-Range: bytes first-last/length`
    (or `bytes */length`) header; None for an unknown length (`/*`).
    Raises on any other form, a range whose last byte precedes its first,
    and a range that ends at or past the stated length."""
    var v = trim(value)
    var sp = v.find(" ")
    if sp < 0 or ascii_lower(sub(v, 0, sp)) != "bytes":
        raise Error("Content-Range '" + value + "' is not a bytes range")
    var rest = trim(sub(v, sp + 1, v.byte_length()))
    var slash = rest.find("/")
    if slash < 0:
        raise Error("Content-Range '" + value + "' has no '/length'")
    var range_part = sub(rest, 0, slash)
    var length_part = sub(rest, slash + 1, rest.byte_length())
    var total = Optional[Int](None)
    if length_part != "*":
        total = _digits(length_part, "the length", value)
    if range_part == "*":
        if not total:
            raise Error("Content-Range '" + value + "' states neither range nor length")
        return total
    var dash = range_part.find("-")
    if dash < 0:
        raise Error("Content-Range '" + value + "' has no 'first-last'")
    var first = _digits(sub(range_part, 0, dash), "the first byte", value)
    var last = _digits(
        sub(range_part, dash + 1, range_part.byte_length()), "the last byte", value
    )
    if last < first:
        raise Error("Content-Range '" + value + "' ends before it starts")
    if total and last >= total.value():
        raise Error("Content-Range '" + value + "' ends past the length")
    return total


# ---- request checksums -------------------------------------------------------

# The algorithm a request checksum is computed with when the caller names
# none: botocore's DEFAULT_CHECKSUM_ALGORITHM.
comptime S3_DEFAULT_CHECKSUM_ALGORITHM = "CRC32"

# The reflected CRC-32 polynomial (ISO-HDLC, the one zlib and S3 use).
comptime _CRC32_POLY: UInt32 = 0xEDB88320


def s3_crc32(data: Span[UInt8, _]) -> UInt32:
    """The CRC-32 of `data` that S3 calls CRC32: CRC-32/ISO-HDLC, reflected
    polynomial 0xEDB88320, initial value and final XOR 0xFFFFFFFF."""
    var table = InlineArray[UInt32, 256](fill=UInt32(0))
    for i in range(256):
        var c = UInt32(i)
        for _ in range(8):
            if (c & UInt32(1)) != UInt32(0):
                c = (c >> UInt32(1)) ^ _CRC32_POLY
            else:
                c = c >> UInt32(1)
        table[i] = c
    var crc = UInt32(0xFFFFFFFF)
    for i in range(len(data)):
        crc = table[Int((crc ^ UInt32(data[i])) & UInt32(0xFF))] ^ (
            crc >> UInt32(8)
        )
    return crc ^ UInt32(0xFFFFFFFF)


def s3_checksum_crc32(data: Span[UInt8, _]) -> String:
    """The `x-amz-checksum-crc32` value of `data`: the base64 of its
    `s3_crc32`, big-endian."""
    var c = s3_crc32(data)
    var be = List[UInt8](capacity=4)
    be.append(UInt8((c >> UInt32(24)) & UInt32(0xFF)))
    be.append(UInt8((c >> UInt32(16)) & UInt32(0xFF)))
    be.append(UInt8((c >> UInt32(8)) & UInt32(0xFF)))
    be.append(UInt8(c & UInt32(0xFF)))
    return base64_encode(Span(be))


def s3_apply_request_checksum(mut req: AwsRequest, algorithm_header: String) raises:
    """Adds the request checksum of `req.body` to `req`, as botocore does
    by default for an operation whose checksum algorithm member is the
    header `algorithm_header` (`x-amz-sdk-checksum-algorithm`).

    - A header named `x-amz-checksum-*` already set: nothing is added (the
      caller supplied the checksum).
    - The algorithm header unset (or empty): it is set to `CRC32`, and
      `x-amz-checksum-crc32` to the body's checksum.
    - The algorithm header `CRC32` (any case): `x-amz-checksum-crc32`.
    - Any other algorithm: refused, naming it. Only CRC32 is computed here;
      a caller choosing another sets its checksum member as well."""
    for i in range(len(req.header_names)):
        if ascii_lower(req.header_names[i]).startswith("x-amz-checksum-"):
            return
    var algorithm = req.header(algorithm_header)
    if algorithm.byte_length() == 0:
        algorithm = String(S3_DEFAULT_CHECKSUM_ALGORITHM)
        req.set_header(algorithm_header, algorithm)
    if ascii_lower(algorithm) != "crc32":
        raise Error(
            "S3 request checksum algorithm '"
            + algorithm
            + "' is not computed by this client (only CRC32 is); set its"
            + " x-amz-checksum-"
            + ascii_lower(algorithm)
            + " member too"
        )
    req.set_header(
        String("x-amz-checksum-crc32"), s3_checksum_crc32(Span(req.body))
    )
