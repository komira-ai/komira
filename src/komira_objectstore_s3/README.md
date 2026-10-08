# komira_objectstore_s3

Amazon S3, and S3-compatible services, as a komira_objectstore store, built on
the generated `komira_aws_s3` client:

- `S3Config`: region, endpoint, addressing style (virtual-hosted or path),
  FIPS and dual-stack, retry policy, request concurrency, listing page size.
  Every setting is a constructor argument, checked when it is built; nothing
  reads the environment.
- `S3Store`: the object verbs (HEAD, GET, ranged and suffix GET,
  ListObjectsV2, DELETE, conditional PUT, multipart upload, coalesced range
  fetch), retried within the store's own retry quota.
  `S3ConditionalStore` presents one bucket as komira_objectstore's
  `CloneableConditionalWriteStore`; `S3Fs` presents one as komira_fs's
  `FileSystem` (each open file reads one object version).
- `classify_http_status` and `s3_store_error`: an S3 answer as a
  `StoreError` kind (a 409 `ConditionalRequestConflict` counts as a lost
  precondition, like a 412) and the one message shape every verb raises.
- `S3ByteRange` and the Content-Range checks: the one place a half-open byte
  window becomes HTTP's closed `Range` header, and the checks a 206 answer
  must pass.
- `S3PresignSigner`: presigned GET and PUT URLs (SigV4 query signing, only
  `host` signed).

Every verb that reaches S3 needs a network and credentials; the examples below
are the parts that run offline: configuration, error mapping, ranges and URL
presigning with a fixed clock.

## Examples

Configuration is checked when it is built:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false, assert_raises -->
```mojo
from komira_objectstore_s3 import AddressingStyle, S3Config, s3_standard_retry_policy

var c = S3Config.aws("eu-west-1")
assert_equal(c.region, "eu-west-1")
assert_false(c.addressing.is_path())  # virtual-hosted by default
assert_equal(c.max_inflight, 64)
assert_equal(c.list_page_size, 1000)

var compatible = S3Config("us-east-1", addressing=AddressingStyle.path(), max_inflight=4, retry=s3_standard_retry_policy())
assert_true(compatible.endpoint_config().force_path_style.value())

with assert_raises(contains="the region is empty"):
    _ = S3Config("", retry=s3_standard_retry_policy())
with assert_raises(contains="list_page_size must be 1 to 1000"):
    _ = S3Config("us-east-1", list_page_size=1001, retry=s3_standard_retry_policy())
```

An S3 answer as an object-store error:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_objectstore import STORE_ERR_NOT_FOUND, STORE_ERR_PRECONDITION, STORE_ERR_THROTTLED
from komira_objectstore_s3 import classify_http_status, s3_store_error, store_error_kind_from_message

assert_equal(classify_http_status(404, "NoSuchKey", "").kind, STORE_ERR_NOT_FOUND)
assert_equal(classify_http_status(409, "ConditionalRequestConflict", "").kind, STORE_ERR_PRECONDITION)
assert_true(classify_http_status(503, "SlowDown", "").is_retryable())
assert_equal(classify_http_status(503, "SlowDown", "").kind, STORE_ERR_THROTTLED)
assert_false(classify_http_status(412, "PreconditionFailed", "").is_retryable())

var message = String(s3_store_error("HeadObject", "lake", "k", 404, "404", ""))
assert_equal(message, "StoreError[NOT_FOUND] HeadObject s3://lake/k status=404 s3_code=404")
assert_equal(store_error_kind_from_message(message), STORE_ERR_NOT_FOUND)
```

Byte ranges, and the check a 206 answer must pass:

<!-- mojo-hidden from std.testing import assert_equal, assert_raises -->
```mojo
from komira_objectstore_s3 import S3ByteRange, s3_check_partial, s3_parse_content_range, s3_suffix_range_header

var asked = S3ByteRange.of_length(10, 4)  # bytes [10, 14)
assert_equal(asked.header(), "bytes=10-13")
assert_equal(s3_suffix_range_header(8), "bytes=-8")

var answered = s3_parse_content_range("bytes 10-13/100")
assert_equal(answered.total, 100)
s3_check_partial(asked, answered, 4)  # the 206 matches what was asked
with assert_raises(contains="starts at byte 9"):
    s3_check_partial(asked, s3_parse_content_range("bytes 9-12/100"), 4)
```

A presigned download URL, signed with a fixed clock and the documentation's
example key, so the signature is reproducible:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_aws_core import AwsCredential, FixedClock, StaticCredsSource
from komira_objectstore_s3 import S3Config, S3PresignSigner

var now = 1790000000  # 20260921T141320Z
var signer = S3PresignSigner[StaticCredsSource, FixedClock](
    "examplebucket",
    S3Config.aws("us-east-1"),
    StaticCredsSource(AwsCredential("AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "")),
    FixedClock(now),
)
var url = signer.presign_download("test.txt", 3600)
assert_equal(url.method, "GET")
assert_equal(url.expires_unix_seconds, Int64(now + 3600))
assert_true("&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20260921%2Fus-east-1%2Fs3%2Faws4_request" in url.url)
assert_true("&X-Amz-SignedHeaders=host&X-Amz-Expires=3600" in url.url)
assert_true(url.url.endswith("&X-Amz-Signature=6798df2c76303ed78e600fe26fee836b2fc1bbe2eb7209fd5c778b0d47d8a347"))
```
