# komira_gcp_secretmanager

A Secret Manager v1 client, generated at build time from the googleapis
protos (`google/cloud/secretmanager/v1`) over REST/JSON.
`SecretManagerServiceClient` carries ten methods: `access_secret_version`
(read a value), `create_secret`, `add_secret_version` (give a secret a new
value), `list_secret_versions`, `list_secrets`, `delete_secret`,
`get_secret`, `update_secret` (change a secret in place, under an update
mask), and `get_iam_policy` and `set_iam_policy` (a secret's IAM policy). The
request types and the `Secret` and `SecretVersion` resources are generated
with it; a request can be written as its proto3 JSON and read with
komira_proto_codec's `decode_json`.

The client sends through a komira_http_client `HttpClient` over the
komira_http_core `Connector` it is given, asks a komira_gcp_core
`GcpTokenSource` for one bearer token per request, and raises a non-2xx
answer through komira_gcp_core's `gcp_status_error`, which never quotes the
body. It starts at `secretmanager.googleapis.com`; `set_rest_host` points it
elsewhere (a regional secret, `projects/*/locations/*/secrets/*`, is sent at
its regional path to the host the caller sets). A resource name that
matches none of a method's paths is refused before the token source is
asked or anything is sent. It reads no environment.

No other Secret Manager method is generated. A retry of `create_secret` or
`add_secret_version` is the caller's decision: a second `add_secret_version`
adds a second version.

## Examples

The examples send through komira_http_core's `ScriptedConnector`, which
answers from a canned response and captures the bytes the client wrote; no
socket is opened. The client is pointed at `localhost` so nothing is looked
up in DNS.

Read the latest version of a secret. The payload arrives base64-encoded
with its CRC32C and is decoded to its bytes:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_secretmanager.service import AccessSecretVersionRequest, SecretManagerServiceClient
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json

comptime Runtime = BlockingRuntime[NoopSink]


def secrets_answering(body: String, sent: ArcPointer[List[UInt8]]) raises -> SecretManagerServiceClient[ScriptedConnector, StaticTokenSource]:
    """A client whose one request is answered 200 with `body`."""
    var text = (
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: " + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n" + body
    )
    var reply = List[UInt8]()
    reply.extend(Span(text.as_bytes()))
    var client = SecretManagerServiceClient[ScriptedConnector, StaticTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(
                ScriptedStream.from_read_script_with_capture(reply^, sent)
            )
        ),
        StaticTokenSource(String("a-token")),
    )
    client.set_rest_host(String("localhost"))
    return client^


var sent = ArcPointer[List[UInt8]](List[UInt8]())
var client = secrets_answering(
    '{"name":"projects/123456789012/secrets/smtp-password/versions/3",'
    + '"payload":{"data":"aHVudGVyMg==","dataCrc32c":"1736498283"}}',
    sent,
)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var version = client.access_secret_version[Runtime](
    decode_json[AccessSecretVersionRequest](
        '{"name":"projects/demo-project/secrets/smtp-password/versions/latest"}'
    ),
    reactor,
)

var wire = String(unsafe_from_utf8=Span(sent[]))
assert_true(wire.startswith(
    "GET /v1/projects/demo-project/secrets/smtp-password/versions/latest:access HTTP/1.1\r\n"
))
assert_true("authorization: Bearer a-token\r\n" in wire)

assert_equal(version.name, "projects/123456789012/secrets/smtp-password/versions/3")
ref payload = version.payload.value()
assert_equal(len(payload.data), 7)  # "hunter2"
assert_equal(payload.data[0], UInt8(ord("h")))
assert_equal(payload.data_crc32c.value(), Int64(1736498283))
```

A name that is not a secret version (here a secret, with no
`/versions/<v>`) matches none of the method's paths: it is refused, and
nothing is sent:

```mojo
var nothing_sent = ArcPointer[List[UInt8]](List[UInt8]())
var refusing = secrets_answering("{}", nothing_sent)
var rt2 = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor2 = rt2.reactor()
var error = String("")
try:
    _ = refusing.access_secret_version[Runtime](
        decode_json[AccessSecretVersionRequest](
            '{"name":"projects/demo-project/secrets/smtp-password"}'
        ),
        reactor2,
    )
except e:
    error = String(e)
assert_true("matches none of its paths" in error)
assert_equal(len(nothing_sent[]), 0)
```
