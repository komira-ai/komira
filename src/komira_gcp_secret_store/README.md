# komira_gcp_secret_store

The resolve seam over GCP Secret Manager, on the generated
`komira_gcp_secretmanager` client, the handle grammar and the payload
checksum.

- `GcpSecretManagerStore[C, T]` is a `komira_secret_store.SecretStore`.
  `resolve(secret_ref)` sends one AccessSecretVersion and returns the
  payload as a zeroizing `SecretValue`, after checking it against the
  `dataCrc32c` the answer must carry (the service keeps one for every
  version, computing it when the writer sent none, and returns it with
  each access; an answer without one is refused). `dataCrc32c` is
  required: the service stores one for every version, so a version ever
  returned without one is refused, which is the safe direction. Bound in a
  `komira_secret_registry.SecretRegistry`, it is what a connector's
  `CredentialConsumer` receives the bytes through.
- `parse_gcp_secret_ref` reads a handle, a resource name as the service
  spells it: `projects/<p>[/locations/<l>]/secrets/<s>` resolves `latest`
  (the most recently created version), and `.../versions/<n>`,
  `.../versions/latest` or `.../versions/<alias>` names a version (an alias
  is 1 to 63 of `A-Z a-z 0-9 _ -`, a letter first, and not `latest` or
  `new` in any case, the names Google reserves). Each part has its shape: a secret
  id is 1 to 255 of `A-Z a-z 0-9 _ -`, a project a project number or a
  project id (optionally domain-scoped), a location a location id. Anything
  else is refused, so a value pasted into a handle field is refused rather
  than sent, and the refusal does not quote it.
- `crc32c` is the CRC-32C the payload checksum is.

The writer, `GcpSecretManagerWriter`, is kci_gcp_secret_writer's. That
package depends on this one for the grammar and the checksum; this one does
not depend on it or on `kci_secret_writer`, so a target that only resolves
has no write verb in its closure.

The store takes the client by value, and the client carries everything that
decides where and as whom a call runs: the endpoint (a regional secret is
served at its own host: build that client with `set_rest_host`), the token
source and the HTTP time budget. The package reads no environment. Every
failure raises, naming the handle and carrying the client's error (the
method, the status and its code, never the body); no error holds a value,
and a handle the grammar refuses is not quoted.

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

var aliased = parse_gcp_secret_ref("projects/demo-project/secrets/smtp/versions/prod")
assert_equal(aliased.version, "prod")

with assert_raises(contains="neither 'latest', a version number nor a version alias"):
    _ = parse_gcp_secret_ref("projects/demo-project/secrets/smtp/versions/03")
with assert_raises(contains="secret id is not 1 to 255"):
    _ = parse_gcp_secret_ref('projects/demo-project/secrets/{"password":"hunter2"}')

assert_equal(Int(crc32c("123456789".as_bytes())), 0xE3069283)
```

A store. Its client answers from a scripted connector, one canned answer;
an application passes a `TlsConnector` and a token source such as
`komira_gcp_core`'s Application Default Credentials, and the store owns its
client:

<!-- mojo-hidden from std.testing import assert_equal, assert_raises -->
```mojo
from komira_gcp_core import StaticTokenSource
from komira_gcp_secret_store import GcpSecretManagerStore
from komira_gcp_secretmanager.service import SecretManagerServiceClient
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

comptime Client = SecretManagerServiceClient[ScriptedConnector, StaticTokenSource]

def _answering(body: String) raises -> Client:
    var http = (
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
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
    '{"name":"projects/000000000000/secrets/smtp/versions/3",'
    + '"payload":{"data":"aHVudGVyMg==","dataCrc32c":"1736498283"}}'
))
var value = store.resolve("projects/demo-project/secrets/smtp")
assert_equal(value.len(), 7)
assert_equal(String(value), "SecretValue(<redacted:7B>)")

var unchecked = GcpSecretManagerStore(_answering(
    '{"name":"projects/000000000000/secrets/smtp/versions/3","payload":{"data":"aHVudGVyMg=="}}'
))
with assert_raises(contains="the answer carries no dataCrc32c"):
    _ = unchecked.resolve("projects/demo-project/secrets/smtp")
```

## Tests

The welded test, `tests/test_gcp_secret_store.mojo`, needs no socket: the
handle grammar and its refusals (the secret-id, project, location and
version shapes, version aliases among them, a pasted value), none quoting the handle; CRC-32C against published
values; a resolve's request line for `latest` and for a version number, the
payload decoded, and a checksum mismatch, an answer with no checksum and an
answer with no payload raised; and an error answer raised naming the handle
without the canary its body carried.

The service's behaviour is tested end to end in
`src/tests/e2e/komira_secrets_e2e` (`test_gcp_store_registry`), against a
stateful fake of Secret Manager behind TLS on a real socket, which verifies
every payload's checksum: values written through kci_gcp_secret_writer's
writer and revealed through `SecretRegistry` into a `CredentialConsumer`, by
secret, by version number and by `latest`, global and regional; a secret
whose `latest` is disabled refused while its older enabled version reads;
and a missing secret raised. No test talks to Google Cloud.
