# komira_aws_logs

Amazon CloudWatch Logs' GetLogEvents, generated at build time from botocore's
pinned `logs` model (awsJson 1.1). The module
`komira_aws_logs.komira_aws_logs` holds:

- `CloudWatchLogsGetLogEventsRequest` and `build_get_log_events_request`,
  which returns a komira_aws_core `AwsRequest` (POST `/`, `X-Amz-Target:
  Logs_20140328.GetLogEvents`, the members in a JSON body, an unset member
  absent);
- `parse_get_log_events_response`, which decodes a page of events and its
  forward and backward tokens from a komira_aws_core `AwsResponse`;
- `resolve_get_log_events_endpoint`, which runs the service's published
  endpoint ruleset (`komira_aws_logs_endpoint_rules()`) over a
  `CloudWatchLogsEndpointConfig`.

It is generated in pure mode: there is no client and no transport, and no
other CloudWatch Logs operation. A caller signs a built request with
komira_aws_core's `build_sigv4_signed_request` (signing name `logs`) and
sends it itself. The package reads no environment.

## Examples

Build the request for the first page of a stream, read from its head:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_aws_logs.komira_aws_logs import CloudWatchLogsGetLogEventsRequest
from komira_aws_logs.komira_aws_logs import build_get_log_events_request

var input = CloudWatchLogsGetLogEventsRequest(String("web/app/0123456789abcdef"))
input.set_log_group_name(String("/ecs/web"))
input.set_limit(Int32(200))
input.set_start_from_head(True)
var req = build_get_log_events_request(input)
assert_equal(req.method, "POST")
assert_equal(req.uri, "/")
assert_equal(req.header(String("X-Amz-Target")), "Logs_20140328.GetLogEvents")
assert_equal(req.header(String("Content-Type")), "application/x-amz-json-1.1")
assert_equal(
    req.body_text(),
    '{"logGroupName":"/ecs/web","logStreamName":"web/app/0123456789abcdef",'
    + '"limit":200,"startFromHead":true}',
)
```

Decode a page of events, and read an error with komira_aws_core's
`aws_json_error_info` (the code from `X-Amzn-Errortype` when present, else
the body's `__type`, cut to the short name):

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_core import AwsResponse, aws_json_error_info
from komira_aws_logs.komira_aws_logs import parse_get_log_events_response

var page = parse_get_log_events_response(
    AwsResponse.of_text(
        200,
        String(
            '{"events":[{"timestamp":1790812800000,"message":"listening",'
            + '"ingestionTime":1790812800412}],'
            + '"nextForwardToken":"f/1","nextBackwardToken":"b/1"}'
        ),
    )
)
var events = page.events.value().copy()
assert_equal(len(events), 1)
assert_equal(events[0].timestamp.value(), Int64(1790812800000))
assert_equal(events[0].message.value(), "listening")
assert_equal(page.next_forward_token.value(), "f/1")

var resp = AwsResponse.of_text(
    400,
    String(
        '{"__type":"com.amazonaws.logs#ResourceNotFoundException",'
        + '"message":"The specified log stream does not exist."}'
    ),
)
var info = aws_json_error_info(resp)
assert_equal(info.status, 400)
assert_equal(info.code, "ResourceNotFoundException")
assert_equal(info.message, "The specified log stream does not exist.")
```

Resolve the endpoint and sign the request. The clock is fixed, so the
signature is the same on every run:

<!-- mojo-hidden
from std.testing import assert_equal
from komira_aws_logs.komira_aws_logs import CloudWatchLogsGetLogEventsRequest, build_get_log_events_request
-->
```mojo
from komira_aws_core import AwsCredential, FixedClock, Header
from komira_aws_core import aws_signing_target, build_sigv4_signed_request
from komira_aws_logs.komira_aws_logs import CloudWatchLogsEndpointConfig
from komira_aws_logs.komira_aws_logs import komira_aws_logs_endpoint_rules
from komira_aws_logs.komira_aws_logs import resolve_get_log_events_endpoint

var input = CloudWatchLogsGetLogEventsRequest(String("web/app/0123456789abcdef"))
input.set_log_group_name(String("/ecs/web"))
input.set_limit(Int32(200))
input.set_start_from_head(True)
var built = build_get_log_events_request(input)

var resolved = resolve_get_log_events_endpoint(
    komira_aws_logs_endpoint_rules(),
    CloudWatchLogsEndpointConfig(String("us-east-1")),
    input,
)
assert_equal(resolved.url, "https://logs.us-east-1.amazonaws.com")
var target = aws_signing_target(resolved, String("us-east-1"), String("logs"))

var extra = List[Header]()
extra.append(Header(String("X-Amz-Target"), built.header(String("X-Amz-Target"))))
var clock = FixedClock(1790812800)  # 2026-10-01T00:00:00Z
var signed = build_sigv4_signed_request(
    built.method,
    AwsCredential(
        String("AKIAIOSFODNN7EXAMPLE"),
        String("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
        String(""),
    ),
    target.signing_region,
    target.signing_name,
    target.endpoint,
    built.uri,
    built.header(String("Content-Type")),
    Span(built.body),
    extra,
    clock,
)
assert_equal(signed.host, "logs.us-east-1.amazonaws.com")
assert_equal(signed.header("X-Amz-Date"), "20261001T000000Z")
assert_equal(
    signed.header("Authorization"),
    "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-east-1/logs/aws4_request, "
    + "SignedHeaders=content-type;host;x-amz-date;x-amz-target, "
    + "Signature=239c73b6922b888b6080898258e8356e04f6f74b6ab82dcbbd5dc0e96709eac6",
)
```
