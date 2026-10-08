# komira_gcp_secret_store

The secret seams over GCP Secret Manager, on the generated
`komira_gcp_secretmanager` client.

- `GcpSecretManagerStore[C, T]` is a `komira_secret_store.SecretStore`.
  `resolve(secret_ref)` sends one AccessSecretVersion and returns the
  payload as a zeroizing `SecretValue`, after checking it against the
  `dataCrc32c` the answer carries. Bound in a
  `komira_secret_registry.SecretRegistry`, it is what a connector's
  `CredentialConsumer` receives the bytes through.
- `GcpSecretManagerWriter[C, T]` is a `kci_secret_writer.SecretWriter`.
  `write` sends AddSecretVersion with the payload's CRC32C and, when the
  secret does not exist, CreateSecret (automatic replication for a global
  secret, none for a regional one) and the add again; `define_container`
  creates a secret with no version (an existing one is the no-op);
  `has_version` lists the secret's versions filtered to `state:ENABLED`,
  one per page, so it needs `versions.list` and never reads a value.
- `parse_gcp_secret_ref` reads a handle, a resource name as the service
  spells it: `projects/<p>[/locations/<l>]/secrets/<s>` resolves `latest`,
  and `.../versions/<n>` or `.../versions/latest` names a version. A writer
  takes the secret's name.
- `crc32c` is the CRC-32C the payload checksum is.

Both take the client by value, and the client carries everything that
decides where and as whom a call runs: the endpoint (a regional secret is
served at its own host: build that client with `set_rest_endpoint`), the
token source and the HTTP time budget. The package reads no environment.
Every failure raises, naming the handle and carrying the client's error
(the method, the status and its code, never the body); no error holds a
value, and a handle the grammar refuses is not quoted. A writer refuses a
non-empty `deploy_token` before sending: the bearer comes from the client's
token source, so a deploy principal's token is given to the client
(`komira_gcp_core.StaticTokenSource`), not to each call.

## Examples

Handles, the version a resolve reads, and what the grammar refuses:

<!-- mojo-hidden from std.testing import assert_equal, assert_raises, assert_true -->
```mojo
from komira_gcp_secret_store import GCP_VERSION_LATEST, GcpSecretRef, crc32c, parse_gcp_secret_ref

var secret: GcpSecretRef = parse_gcp_secret_ref("projects/demo-project/secrets/smtp")
assert_true(not secret.names_version())
assert_equal(secret.secret_name(), "projects/demo-project/secrets/smtp")
assert_equal(secret.version_name(), "projects/demo-project/secrets/smtp/versions/" + GCP_VERSION_LATEST)

var regional = parse_gcp_secret_ref("projects/demo-project/locations/us-central1/secrets/smtp/versions/3")
assert_true(regional.is_regional())
assert_equal(regional.parent(), "projects/demo-project/locations/us-central1")

with assert_raises(contains="neither 'latest' nor a version number"):
    _ = parse_gcp_secret_ref("projects/demo-project/secrets/smtp/versions/03")

assert_equal(Int(crc32c("123456789".as_bytes())), 0xE3069283)
```

A store and a writer. The clients here answer from scripted connectors,
one canned answer per client; an application passes a `TlsConnector` and a
token source such as `komira_gcp_core`'s Application Default Credentials,
and the store and the writer each own their client:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_raises, assert_true -->
```mojo
from komira_gcp_core import StaticTokenSource
from komira_gcp_secret_store import GCP_ENABLED_FILTER, GcpSecretManagerStore, GcpSecretManagerWriter
from komira_gcp_secretmanager.service import SecretManagerServiceClient
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_secret_store import SecretValue

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

var store = GcpSecretManagerStore(_answering(
    "200 OK",
    '{"name":"projects/000000000000/secrets/smtp/versions/3",'
    + '"payload":{"data":"aHVudGVyMg==","dataCrc32c":"1736498283"}}',
))
var value = store.resolve("projects/demo-project/secrets/smtp")
assert_equal(value.len(), 7)
assert_equal(String(value), "SecretValue(<redacted:7B>)")

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

var empty = GcpSecretManagerWriter(_answering("200 OK", "{}"))
assert_false(empty.has_version("projects/demo-project/secrets/smtp", ""))  # no enabled version
assert_equal(GCP_ENABLED_FILTER, "state:ENABLED")
```

## Tests

The welded test, `tests/test_gcp_secret_store.mojo`, needs no socket: the
handle grammar and its refusals; CRC-32C against published values; a
resolve's request line for `latest` and for a version number, the payload
decoded, a checksum mismatch and an answer with no payload raised; an error
answer raised naming the handle without the canary its body carried; the
write's request (payload and `dataCrc32c`) and the probe's (`pageSize=1`,
`filter=state:ENABLED`) as they reached the wire; and the writer's
refusals (a deploy token, a version handle) with nothing written.

The service's behaviour is tested end to end in
`src/tests/e2e/komira_secrets_e2e` (`test_gcp_store_registry`), against a
stateful fake of Secret Manager behind TLS on a real socket, which verifies
every payload's checksum: values written through the writer and revealed
through `SecretRegistry` into a `CredentialConsumer`, by secret, by version
number and by `latest`, global and regional; create-if-absent at each
endpoint, an idempotent define, the probe on a missing, empty and written
secret, a probe with a rejected token raising, and the request log exactly.
No test talks to Google Cloud.
