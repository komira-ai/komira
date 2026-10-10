# komira_aws_s3

An Amazon S3 client for the operations an object store needs, generated at
build time from botocore's pinned `s3` model (restXml). The module
`komira_aws_s3.komira_aws_s3` holds, for GetObject, HeadObject, PutObject,
CopyObject, DeleteObject, DeleteObjects, ListBuckets, ListObjects,
ListObjectsV2 and the multipart upload operations (CreateMultipartUpload,
UploadPart, CompleteMultipartUpload, AbortMultipartUpload):

- a request struct (`S3<Operation>Request`) and its builder
  `build_<operation>_request`, which returns a komira_aws_core `AwsRequest`
  whose target starts at the key (the bucket is the endpoint's);
- a response parser `parse_<operation>_response` over a komira_aws_core
  `AwsResponse` (and `parse_get_object_head`, which reads a GetObject's
  headers without its body);
- an endpoint resolver `resolve_<operation>_endpoint`, which runs S3's
  published endpoint ruleset (`komira_aws_s3_endpoint_rules()`) over an
  `S3EndpointConfig` and puts the bucket in the host (virtual host) or in the
  path (when the bucket cannot be a host name, or `force_path_style` is set,
  as a custom endpoint such as MinIO or LocalStack needs);
- `S3Client`, which resolves each call's endpoint, signs it with SigV4 per
  attempt and sends it over the komira_http_core `Connector` it is given,
  retried as the AWS SDKs' standard mode retries.

Beyond the model, as botocore does: a 200 whose body is an `<Error>` is
raised as an HTTP 500 on the operations where S3 answers that way;
PutObject, UploadPart and DeleteObjects carry a CRC32 request checksum; an
`Expires` header that is not a date is left unset. SSE-C key encoding and
other operations (bucket ACLs, SelectObjectContent among them) are not
provided. The package reads no environment.

## Examples

Build a conditional PutObject (create only if the key is absent). The
request carries the CRC32 checksum header; nothing is sent:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_aws_s3.komira_aws_s3 import S3PutObjectRequest, build_put_object_request

var input = S3PutObjectRequest(String("lake"), String("manifest.json"))
var body = List[UInt8]()
body.extend(Span(String('{"v":1}').as_bytes()))
input.set_body(body^)
input.set_if_none_match(String("*"))
var req = build_put_object_request(input)
assert_equal(req.method, "PUT")
assert_equal(req.uri, "/manifest.json")
assert_equal(req.header(String("If-None-Match")), "*")
assert_equal(req.header(String("x-amz-sdk-checksum-algorithm")), "CRC32")
assert_equal(req.header(String("x-amz-checksum-crc32")), "hNvnPQ==")
assert_equal(req.body_text(), '{"v":1}')
```

A ranged GetObject, and the headers of its 206 answer:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_core import AwsResponse
from komira_aws_s3.komira_aws_s3 import S3GetObjectRequest, build_get_object_request
from komira_aws_s3.komira_aws_s3 import parse_get_object_head, parse_get_object_response

var get = S3GetObjectRequest(String("lake"), String("data/part-00000.parquet"))
get.set_range_(String("bytes=0-9"))
var get_req = build_get_object_request(get)
assert_equal(get_req.method, "GET")
assert_equal(get_req.uri, "/data/part-00000.parquet")
assert_equal(get_req.header(String("Range")), "bytes=0-9")

var payload = List[UInt8]()
payload.extend(Span(String("0123456789").as_bytes()))
var resp = AwsResponse(206, payload^)
resp.add_header(String("Content-Range"), String("bytes 0-9/52428800"))
resp.add_header(String("Content-Length"), String("10"))
resp.add_header(String("ETag"), String('"9b2cf535f27731c974343645a3985328"'))
var head = parse_get_object_head(resp)
assert_equal(head.content_range.value(), "bytes 0-9/52428800")
assert_equal(head.content_length.value(), Int64(10))
assert_equal(head.e_tag.value(), '"9b2cf535f27731c974343645a3985328"')
var full = parse_get_object_response(resp)
assert_equal(len(full.body.value()), 10)
```

Decode a ListObjectsV2 page, and read an error with komira_aws_core's
`aws_rest_xml_error`:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
from komira_aws_core import AwsResponse
-->
```mojo
from komira_aws_core import aws_rest_xml_error
from komira_aws_s3.komira_aws_s3 import parse_list_objects_v2_response

var page = parse_list_objects_v2_response(
    AwsResponse.of_text(
        200,
        String(
            '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
            + "<Name>lake</Name><KeyCount>1</KeyCount><IsTruncated>true</IsTruncated>"
            + "<Contents><Key>data/a.parquet</Key><Size>1024</Size></Contents>"
            + "<NextContinuationToken>next-1</NextContinuationToken>"
            + "</ListBucketResult>"
        ),
    )
)
assert_equal(page.name.value(), "lake")
assert_true(page.is_truncated.value())
assert_equal(page.next_continuation_token.value(), "next-1")
var contents = page.contents.value().copy()
assert_equal(len(contents), 1)
assert_equal(contents[0].key.value(), "data/a.parquet")
assert_equal(contents[0].size.value(), Int64(1024))

var missing = AwsResponse.of_text(
    404,
    String(
        "<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message>"
        + "<RequestId>4442587FB7D0A2F9</RequestId></Error>"
    ),
)
var info = aws_rest_xml_error(missing)
assert_equal(info.status, 404)
assert_equal(info.code, "NoSuchKey")
```

Resolve where a request goes: virtual-host addressing by default, path style
when asked for:

<!-- mojo-hidden
from std.testing import assert_equal
from komira_aws_s3.komira_aws_s3 import S3GetObjectRequest, build_get_object_request
-->
```mojo
from komira_aws_core import aws_signing_target
from komira_aws_s3.komira_aws_s3 import S3EndpointConfig, komira_aws_s3_endpoint_rules
from komira_aws_s3.komira_aws_s3 import resolve_get_object_endpoint

var rules = komira_aws_s3_endpoint_rules()
var input = S3GetObjectRequest(String("lake"), String("data/a.parquet"))
var virtual = resolve_get_object_endpoint(rules, S3EndpointConfig(String("us-west-2")), input)
assert_equal(virtual.url, "https://lake.s3.us-west-2.amazonaws.com")
var target = aws_signing_target(virtual, String("us-west-2"), String("s3"))
assert_equal(target.signing_name, "s3")
assert_equal(
    target.endpoint.url_for(build_get_object_request(input).uri),
    "https://lake.s3.us-west-2.amazonaws.com/data/a.parquet",
)

var path_style = S3EndpointConfig(String("us-west-2"))
path_style.force_path_style = Optional[Bool](True)
assert_equal(
    resolve_get_object_endpoint(rules, path_style, input).url,
    "https://s3.us-west-2.amazonaws.com/lake",
)
```
