# =============================================================================
# komira_aws_core/s3_wire.mojo -- the two S3 header values no model states
# =============================================================================
#
# Everything else about S3's wire form comes from the service model and the
# endpoint ruleset. These two do not:
#
#   - `s3_copy_source`: the `x-amz-copy-source` value of CopyObject and
#     UploadPartCopy. The model types it as a plain string; botocore builds
#     it in `_quote_source_header_from_dict` (botocore/handlers.py):
#     `<bucket>/<key>`, or `<access point ARN>/object/<key>`, percent-encoded
#     with '/' kept, then `?versionId=<id>` appended as given.
#   - `s3_content_range_total`: the complete length a `Content-Range`
#     response header states (RFC 9110 section 14.4), which a ranged
#     GetObject needs to learn the object's size.
# =============================================================================

from ._regex import Regex
from ._text import ascii_lower, sub, trim
from .sigv4 import uri_encode


# botocore's VALID_S3_ARN (botocore/handlers.py): an access point ARN, or an
# Outposts access point ARN. A bucket matching either names an access point,
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
    if Regex(_ACCESS_POINT_ARN).matches(bucket) or Regex(_OUTPOST_ARN).matches(
        bucket
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
