# komira_aws_core

The hand-written AWS runtime under the generated `komira_aws_<service>`
clients. It holds:

- `AwsCredential` and AWS Signature Version 4: header signing
  (`build_sigv4_signed_request`, the socket-free half of a send), query
  signing for presigned URLs (`sigv4_presign`) and a signing key cache.
- The AWS SDK default credential chain (`resolve_aws_credentials`,
  `resolve_aws_region`): explicit parameters, the standard `AWS_*`
  environment variables, web identity, the shared config and credentials
  files, the container endpoint and instance metadata, in that order. The
  environment, the files, the network and the clock are seams
  (`EnvSource`, `FileSource`, `CredentialTransport`, `AwsClock`); `MapEnv`,
  `MapFiles` and `FixedClock` are in-memory ones, and `ProcessEnv`,
  `ProcessFiles` and `SystemAwsClock` read the real process.
- The wire runtime a generated client calls: `AwsRequest` / `AwsResponse`,
  the awsJson, awsQuery / ec2Query, restJson1 and restXml codecs, and the
  error readers (`aws_json_error_info`, `aws_query_error`,
  `aws_xml_error_info`).
- Endpoint resolution: `EndpointRuleSet`, an interpreter of a service's
  Smithy endpoint ruleset over the partitions table, and
  `aws_signing_target`.
- The send: `send_sigv4_signed_request` signs, sends over a
  `komira_http_core` `Connector` and retries as botocore's standard mode
  does (`AwsRetryClassifier`, `AwsRetryQuota`). `AwsEchoConnector` is a test
  double that answers each request with its own head.

It has no service operations of its own: those are the generated clients.
Nothing here reads the environment or a file except through the seams
above.

## Examples

A request signed with SigV4 at a fixed clock, with the documentation's
example key (no real credential, no network). The `Authorization` value is
the one an independent SigV4 implementation computes for the same bytes:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_aws_core import AwsCredential, AwsEndpoint, AwsRequest, FixedClock, Header, build_sigv4_signed_request, resolve_endpoint

# The operation's request, as a generated `build_<op>_request` returns it.
var op = AwsRequest(String("POST"), String("/"))
op.set_header(String("X-Amz-Target"), String("AmazonSQS.ListQueues"))
op.set_body_text(String('{"QueueNamePrefix":"komira"}'))

var extra: List[Header] = [Header(String("X-Amz-Target"), String("AmazonSQS.ListQueues"))]
var clock = FixedClock(1789819200)  # 2026-09-19T12:00:00Z
var signed = build_sigv4_signed_request(
    op.method,
    AwsCredential(String("AKIDEXAMPLE"), String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"), String("")),
    String("us-east-1"),
    String("sqs"),
    resolve_endpoint(Optional[AwsEndpoint](), "sqs.us-east-1.amazonaws.com"),
    op.uri,
    String("application/x-amz-json-1.0"),
    Span(op.body),
    extra,
    clock,
)
assert_equal(signed.host, "sqs.us-east-1.amazonaws.com")
assert_equal(signed.header("X-Amz-Date"), "20260919T120000Z")
assert_equal(
    signed.header("Authorization"),
    "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20260919/us-east-1/sqs/aws4_request, "
    + "SignedHeaders=content-type;host;x-amz-date;x-amz-target, "
    + "Signature=adc12ae3fb53dd6bd84d4e3d83cced795f392b959673a4323604188e64e6d52b",
)
# The secret signs; it is never sent.
assert_true(String(unsafe_from_utf8=Span(signed.to_wire())).find("wJalrXUtnFEMI") < 0)
```

The default credential chain over an in-memory environment and in-memory
files: `AWS_PROFILE` picks a profile of the shared credentials file, and the
region comes from the shared config file. Nothing here reads the real
environment, the real home directory or the network; a program passes
`ProcessEnv`, `ProcessFiles` and a real transport instead.

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo module
from komira_aws_core import AwsCredentialParams, CredentialHttpRequest, CredentialHttpResponse, CredentialTransport, FixedClock, MapEnv, MapFiles, resolve_aws_credentials, resolve_aws_region


struct NoNetwork(CredentialTransport, Movable):
    """A transport for a chain that must not reach the network."""

    def __init__(out self):
        pass

    def send(mut self, req: CredentialHttpRequest) raises -> CredentialHttpResponse:
        raise Error("this example opens no connection")


def main() raises:
    var env = MapEnv()
    env.set("HOME", "/home/example")
    env.set("AWS_PROFILE", "deploy")
    var files = MapFiles()
    files.put("/home/example/.aws/config", "[profile deploy]\nregion = eu-west-1\n")
    files.put(
        "/home/example/.aws/credentials",
        "[deploy]\naws_access_key_id = AKIAIOSFODNN7EXAMPLE\n"
        + "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n",
    )
    var params = AwsCredentialParams()
    var transport = NoNetwork()
    var clock = FixedClock(1790812800)

    var resolved = resolve_aws_credentials(params, env, files, transport, clock)
    assert_equal(resolved.source, "profile deploy")
    assert_equal(resolved.credential.access_key_id, "AKIAIOSFODNN7EXAMPLE")
    assert_equal(resolve_aws_region(params, env, files), "eu-west-1")
```

Reading a failed answer: an awsJson error (the code from `__type`, cut to
its short name) and an awsQuery error document:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_aws_core import AwsResponse, aws_is_error_status, aws_json_error_info, aws_query_error

var resp = AwsResponse.of_text(
    400,
    String('{"__type":"com.amazonaws.dynamodb.v20120810#ResourceNotFoundException","message":"Requested resource not found"}'),
)
resp.add_header(String("x-amzn-RequestId"), String("req-1"))
assert_true(aws_is_error_status(resp.status))
var info = aws_json_error_info(resp)
assert_equal(info.code, "ResourceNotFoundException")
assert_equal(info.message, "Requested resource not found")
assert_equal(info.request_id, "req-1")

var e = aws_query_error(
    AwsResponse.of_text(
        404,
        String(
            "<ErrorResponse><Error><Type>Sender</Type><Code>NoSuchEntity</Code>"
            + "<Message>The role with name gone cannot be found.</Message></Error>"
            + "<RequestId>req-2</RequestId></ErrorResponse>"
        ),
    )
)
assert_equal(e.status, 404)
assert_equal(e.code, "NoSuchEntity")
assert_equal(e.request_id, "req-2")
```
