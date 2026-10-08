# komira_aws_secret_store

The secret seams over AWS Secrets Manager, on the generated
`komira_aws_secretsmanager` client.

- `AwsSecretsManagerStore[C, T]` is a `komira_secret_store.SecretStore`.
  `resolve(secret_ref)` sends one GetSecretValue and returns the version's
  SecretString bytes (or its SecretBinary bytes) as a zeroizing
  `SecretValue`. Bound in a `komira_secret_registry.SecretRegistry`, it is
  what a connector's `CredentialConsumer` receives the bytes through.
- `AwsSecretsManagerWriter[C, T]` is a `kci_secret_writer.SecretWriter`.
  `write` sends PutSecretValue (a new AWSCURRENT version) and, when the
  secret does not exist, CreateSecret with the value; `define_container`
  creates a secret with no version (an existing one is the no-op);
  `has_version` reads DescribeSecret, metadata only, and answers whether a
  version holds AWSCURRENT. A secret scheduled for deletion raises.
- `parse_aws_secret_ref` reads a handle: `<SecretId>` (a name or an ARN)
  resolves the AWSCURRENT version; `<SecretId>?versionStage=<label>` and
  `<SecretId>?versionId=<id>` pin one. A writer takes the bare `<SecretId>`.

Both take the client by value, and the client carries everything that
decides where and as whom a call runs: the endpoint, the region, the
credential source and the HTTP time budget. The package reads no
environment. Every failure raises, naming the handle and carrying the
client's error (status, code, the service's message; never a response
body); no error holds a value, and a handle the grammar refuses is not
quoted. A writer refuses a non-empty `deploy_token` before sending:
Secrets Manager signs with the client's credentials, so the deploy
principal is chosen by the credential source the client is built over.

## Examples

Handles, and what the grammar refuses:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_raises, assert_true -->
```mojo
from komira_aws_secret_store import AWS_SELECTOR_VERSION_ID, AWS_SELECTOR_VERSION_STAGE, AwsSecretRef, parse_aws_secret_ref

var current: AwsSecretRef = parse_aws_secret_ref("app/db")
assert_true(current.is_plain())

var pinned = parse_aws_secret_ref(String("app/db?") + AWS_SELECTOR_VERSION_ID + "=a1b2c3d4-5678-90ab-cdef-EXAMPLE11111")
assert_equal(pinned.version_id.value(), "a1b2c3d4-5678-90ab-cdef-EXAMPLE11111")
assert_equal(AWS_SELECTOR_VERSION_STAGE, "versionStage")

var previous = parse_aws_secret_ref("app/db?versionStage=AWSPREVIOUS")
assert_equal(previous.secret_id, "app/db")
assert_equal(previous.version_stage.value(), "AWSPREVIOUS")
assert_false(previous.is_plain())

with assert_raises(contains="neither versionId nor versionStage"):
    _ = parse_aws_secret_ref("app/db?label=AWSPREVIOUS")
```

A store and a writer. The clients here answer from scripted connectors,
one canned answer per client; an application passes `KernelTcpConnector`
behind TLS and its own credential source, and the store and the writer each
own their client:

<!-- mojo-hidden from std.testing import assert_equal, assert_raises, assert_true -->
```mojo
from komira_aws_core import AwsCredential, StaticCredsSource
from komira_aws_secret_store import AWS_STAGE_CURRENT, AwsSecretsManagerStore, AwsSecretsManagerWriter
from komira_aws_secretsmanager.komira_aws_secretsmanager import SecretsManagerClient, SecretsManagerEndpointConfig
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_secret_store import SecretValue

def _ok(body: String) raises -> ScriptedConnector:
    var http = (
        "HTTP/1.1 200 OK\r\nContent-Type: application/x-amz-json-1.1\r\n"
        + "Content-Length: " + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n" + body
    )
    var raw = List[UInt8]()
    raw.extend(Span(http.as_bytes()))
    return ScriptedConnector.with_stream(ScriptedStream.from_read_script(raw^))

def _value() raises -> ScriptedConnector:
    return _ok('{"Name":"app/db","SecretString":"hunter2"}')

def _put() raises -> ScriptedConnector:
    return _ok('{"Name":"app/db","VersionId":"a1b2c3d4-5678-90ab-cdef-EXAMPLE11111"}')

def _described() raises -> ScriptedConnector:
    return _ok('{"Name":"app/db","VersionIdsToStages":{"a1b2c3d4-5678-90ab-cdef-EXAMPLE11111":["AWSCURRENT"]}}')

def _client[C: Connector](mk: def () raises thin -> C) raises -> SecretsManagerClient[C, StaticCredsSource]:
    var config = SecretsManagerEndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return SecretsManagerClient[C, StaticCredsSource](
        mk,
        HttpClientConfig.defaults(),
        StaticCredsSource(AwsCredential("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "")),
        "us-east-1",
        config^,
    )

var store = AwsSecretsManagerStore(_client(_value))
var value = store.resolve("app/db")
assert_equal(value.len(), 7)
assert_equal(String(value), "SecretValue(<redacted:7B>)")

var writer = AwsSecretsManagerWriter(_client(_put))
writer.write("app/db", SecretValue.from_string("rotated"), "")
with assert_raises(contains="a deploy token was given"):
    writer.define_container("app/db", "a-bearer-token")

var probe = AwsSecretsManagerWriter(_client(_described))
assert_true(probe.has_version("app/db", ""))  # a version holds AWS_STAGE_CURRENT
assert_equal(AWS_STAGE_CURRENT, "AWSCURRENT")
```

## Tests

The welded test, `tests/test_aws_secret_store.mojo`, needs no socket: the
handle grammar and its refusals; a resolve of a SecretString, of a
SecretBinary and of an answer with neither (raised); an error answer raised
naming the handle, without the canary value its body carried; and every
writer refusal (a deploy token, a handle with a selector, an ARN to define,
a value that is not UTF-8) made before the connector is dialled.

The service's behaviour is tested end to end in
`src/tests/e2e/komira_secrets_e2e` (`test_aws_store_registry`), against a
stateful fake of Secrets Manager on a real socket: values written through
the writer and revealed through `SecretRegistry` into a `CredentialConsumer`,
by name, by staging label, by version id and by ARN; create-if-absent, an
idempotent define, the probe on a missing, empty and written secret, a
secret scheduled for deletion, a wrongly keyed probe raising, and the
request log exactly. No test talks to AWS.
