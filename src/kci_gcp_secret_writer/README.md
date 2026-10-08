# kci_gcp_secret_writer

The write seam over GCP Secret Manager, on the generated
`komira_gcp_secretmanager` client.

`GcpSecretManagerWriter[C, T]` is a `kci_secret_writer.SecretWriter`.
`write` sends AddSecretVersion with the payload's CRC32C and, when the
secret does not exist, CreateSecret (automatic replication for a global
secret, none for a regional one) and the add again; when that create finds
the id taken (another writer created it in between), the add again.
`define_container` creates a secret with no version (an existing one is the
no-op). `has_version` sends GetSecretVersion for `<secret>/versions/latest`,
metadata only (it needs `secretmanager.versions.get`, never `.access`), and
answers whether that version is ENABLED. `latest` is the most recently
created version and is what a bare handle resolves to, so a secret whose
newest version is disabled answers False even when an older one is enabled:
the bare handle cannot be read, and a write is what makes it readable. A
missing secret, or one with no version, answers False; any other error
raises.

A writer's handle names a secret, in komira_gcp_secret_store's grammar
(`parse_gcp_secret_ref`); a handle naming a version is refused. The resolve
seam, `GcpSecretManagerStore`, is in that package, and it does not depend
on this one: a target that only resolves has no writer in its closure.

The writer takes the client by value, and the client carries everything that
decides where and as whom a call runs: the endpoint (a regional secret is
served at its own host: build that client with `set_rest_host`), the token
source and the HTTP time budget. The package reads no environment. Every
failure raises, naming the handle and carrying the client's error (the
method, the status and its code, never the body); no error holds a value. A
writer refuses a non-empty `deploy_token` before sending: the bearer comes
from the client's token source, so a deploy principal's token is given to
the client (`komira_gcp_core.StaticTokenSource`), not to each call.

## Examples

A writer and its probe. The clients here answer from scripted connectors,
one canned answer per client; an application passes a `TlsConnector` and a
token source such as `komira_gcp_core`'s Application Default Credentials:

<!-- mojo-hidden from std.testing import assert_false, assert_raises, assert_true -->
```mojo
from komira_gcp_core import StaticTokenSource
from komira_gcp_secretmanager.service import SecretManagerServiceClient
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_secret_store import SecretValue

from kci_gcp_secret_writer import GcpSecretManagerWriter

comptime Client = SecretManagerServiceClient[ScriptedConnector, StaticTokenSource]

def _answering(status: String, body: String) raises -> Client:
    var http = (
        "HTTP/1.1 " + status + "\r\nContent-Type: application/json\r\nContent-Length: "
        + String(body.byte_length()) + "\r\nConnection: close\r\n\r\n" + body
    )
    var raw = List[UInt8]()
    raw.extend(Span(http.as_bytes()))
    var client = Client(
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script(raw^))
        ),
        StaticTokenSource("an-access-token"),
    )
    client.set_rest_host("localhost")
    return client^

var writer = GcpSecretManagerWriter(_answering(
    "200 OK", '{"name":"projects/000000000000/secrets/smtp/versions/4","state":"ENABLED"}'
))
writer.write("projects/demo-project/secrets/smtp", SecretValue.from_string("rotated"), "")
with assert_raises(contains="the handle names a version"):
    writer.write("projects/demo-project/secrets/smtp/versions/4", SecretValue.from_string("x"), "")

var existing = GcpSecretManagerWriter(_answering(
    "409 Conflict", '{"error":{"code":409,"message":"exists","status":"ALREADY_EXISTS"}}'
))
existing.define_container("projects/demo-project/secrets/smtp", "")  # already there: no-op

var enabled = GcpSecretManagerWriter(_answering(
    "200 OK", '{"name":"projects/000000000000/secrets/smtp/versions/4","state":"ENABLED"}'
))
assert_true(enabled.has_version("projects/demo-project/secrets/smtp", ""))
var disabled = GcpSecretManagerWriter(_answering(
    "200 OK", '{"name":"projects/000000000000/secrets/smtp/versions/4","state":"DISABLED"}'
))
assert_false(disabled.has_version("projects/demo-project/secrets/smtp", ""))  # latest unreadable
var none = GcpSecretManagerWriter(_answering(
    "404 Not Found", '{"error":{"code":404,"message":"not found","status":"NOT_FOUND"}}'
))
assert_false(none.has_version("projects/demo-project/secrets/smtp", ""))  # no latest
```

## Tests

The welded test, `tests/test_gcp_secret_writer.mojo`, needs no socket: the
write's request (payload and `dataCrc32c`) as it reached the wire; the
create-if-absent race (AddSecretVersion answered 404, CreateSecret answered
409, AddSecretVersion again: three request lines, in that order) and a
create refused for another reason (raised, two requests); the probe's
request line (`GET .../versions/latest`) and its reading of ENABLED,
DISABLED, DESTROYED, NOT_FOUND and PERMISSION_DENIED; and the writer's
refusals (a deploy token, a version handle, a handle outside the grammar)
with nothing written.

The service's behaviour is tested end to end in
`src/tests/e2e/komira_secrets_e2e` (`test_gcp_store_registry`), against a
stateful fake of Secret Manager behind TLS on a real socket, which verifies
every payload's checksum: create-if-absent at each endpoint, an idempotent
define, the probe on a missing, empty, written and disabled-`latest` secret
(the last answering False while its resolve is refused and its older
enabled version reads), a probe with a rejected token raising, and the
request log exactly. No test talks to Google Cloud.
