# komira_aws_sqs

An Amazon SQS client, generated at build time from botocore's pinned `sqs`
model (awsJson 1.0). The module `komira_aws_sqs.komira_aws_sqs` holds, for each
of the operations it carries (CreateQueue, GetQueueUrl, GetQueueAttributes,
SetQueueAttributes, ReceiveMessage, DeleteMessage, DeleteQueue):

- a request struct (`SQS<Operation>Request`) and its builder
  `build_<operation>_request`, which returns a komira_aws_core `AwsRequest`;
- a response parser `parse_<operation>_response` over a komira_aws_core
  `AwsResponse`;
- an endpoint resolver `resolve_<operation>_endpoint`, which runs the
  service's published endpoint ruleset (`komira_aws_sqs_endpoint_rules()`)
  over an `SQSEndpointConfig`;
- `SQSClient`, which resolves each call's endpoint, signs it with SigV4
  (signing name `sqs`) and sends it over the komira_http_core `Connector` it
  is given, retrying throttles, 5xx answers and failed sends as botocore's
  standard mode does.

SQS's other operations (SendMessage among them) are not generated. The
package reads no environment: the region, the endpoint, the credentials and
the transport are the caller's. Every request carries
`x-amzn-query-mode: true`, and an error's code is read from SQS's
`x-amzn-query-error` header (the legacy query code, such as
`AWS.SimpleQueueService.NonExistentQueue`), as botocore reports it.

## Examples

Build a long-poll ReceiveMessage request. Nothing is sent; the request is
plain data:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_aws_sqs.komira_aws_sqs import SQSReceiveMessageRequest, build_receive_message_request

var input = SQSReceiveMessageRequest(
    String("https://sqs.us-east-1.amazonaws.com/123456789012/jobs")
)
input.set_max_number_of_messages(Int32(10))
input.set_wait_time_seconds(Int32(20))
var req = build_receive_message_request(input)
assert_equal(req.method, "POST")
assert_equal(req.uri, "/")
assert_equal(req.header(String("X-Amz-Target")), "AmazonSQS.ReceiveMessage")
assert_equal(req.header(String("x-amzn-query-mode")), "true")
assert_equal(
    req.body_text(),
    '{"QueueUrl":"https://sqs.us-east-1.amazonaws.com/123456789012/jobs",'
    + '"MaxNumberOfMessages":10,"WaitTimeSeconds":20}',
)
```

Decode a ReceiveMessage answer, and read an error the way the client does
(the code from the `x-amzn-query-error` header, the modeled error shape from
the body):

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_core import AwsResponse, aws_json_error_info
from komira_aws_sqs.komira_aws_sqs import SQSQueueDoesNotExist, parse_receive_message_response
from komira_json import parse_json_value

var out = parse_receive_message_response(
    AwsResponse.of_text(
        200,
        String(
            '{"Messages":[{"MessageId":"m-1","ReceiptHandle":"handle-1",'
            + '"Body":"hello"}]}'
        ),
    )
)
var msgs = out.messages.value().copy()
assert_equal(len(msgs), 1)
assert_equal(msgs[0].body.value(), "hello")
assert_equal(msgs[0].receipt_handle.value(), "handle-1")

var resp = AwsResponse.of_text(
    400,
    String(
        '{"__type":"com.amazonaws.sqs#QueueDoesNotExist",'
        + '"message":"The specified queue does not exist."}'
    ),
)
resp.add_header(
    String("x-amzn-query-error"),
    String("AWS.SimpleQueueService.NonExistentQueue;Sender"),
)
var info = aws_json_error_info(resp)
assert_equal(info.code, "AWS.SimpleQueueService.NonExistentQueue")
var err = SQSQueueDoesNotExist.from_aws_json(parse_json_value(resp.body_text()))
assert_equal(err.message.value(), "The specified queue does not exist.")
```

Resolve the endpoint a call goes to, through the embedded ruleset:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_sqs.komira_aws_sqs import SQSEndpointConfig, SQSGetQueueUrlRequest, komira_aws_sqs_endpoint_rules
from komira_aws_sqs.komira_aws_sqs import resolve_get_queue_url_endpoint

var rules = komira_aws_sqs_endpoint_rules()
var regional = resolve_get_queue_url_endpoint(
    rules, SQSEndpointConfig(String("eu-west-1")), SQSGetQueueUrlRequest(String("jobs"))
)
assert_equal(regional.url, "https://sqs.eu-west-1.amazonaws.com")
var fips = SQSEndpointConfig(String("us-east-1"))
fips.use_fips = Optional[Bool](True)
assert_equal(
    resolve_get_queue_url_endpoint(rules, fips, SQSGetQueueUrlRequest(String("jobs"))).url,
    "https://sqs-fips.us-east-1.amazonaws.com",
)
```

The client, given a connector. Here it is komira_http_core's
`ScriptedConnector`, which answers from a canned HTTP response and opens no
socket; a real program passes a TCP or TLS connector instead:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_core import AwsCredential, StaticCredsSource
from komira_aws_sqs.komira_aws_sqs import SQSClient, SQSEndpointConfig, SQSGetQueueUrlRequest
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

def _sqs_answer() raises -> ScriptedConnector:
    var body = String('{"QueueUrl":"http://localhost:9324/000000000000/jobs"}')
    var wire = (
        String("HTTP/1.1 200 OK\r\nContent-Type: application/x-amz-json-1.0\r\n")
        + "Content-Length: " + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n" + body
    )
    var bytes = List[UInt8]()
    bytes.extend(Span(wire.as_bytes()))
    return ScriptedConnector.with_stream(ScriptedStream.from_read_script(bytes^))

var config = SQSEndpointConfig()
config.endpoint = Optional[String](String("http://localhost:9324"))
var client = SQSClient[ScriptedConnector, StaticCredsSource](
    _sqs_answer,
    HttpClientConfig.defaults(),
    StaticCredsSource(
        AwsCredential(String("AKIDEXAMPLE"), String("secret-example"), String(""))
    ),
    String("us-east-1"),
    config^,
)
var found = client.get_queue_url(SQSGetQueueUrlRequest(String("jobs")))
assert_equal(found.queue_url.value(), "http://localhost:9324/000000000000/jobs")
```
