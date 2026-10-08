# komira_aws_secret_store

The resolve seam over AWS Secrets Manager, on the generated
`komira_aws_secretsmanager` client, and the handle grammar.

- `AwsSecretsManagerStore[C, T]` is a `komira_secret_store.SecretStore`.
  `resolve(secret_ref)` sends one GetSecretValue and returns the version's
  SecretString bytes (or its SecretBinary bytes) as a zeroizing
  `SecretValue`. Bound in a `komira_secret_registry.SecretRegistry`, it is
  what a connector's `CredentialConsumer` receives the bytes through.
- `parse_aws_secret_ref` reads a handle: `<SecretId>` resolves the
  AWSCURRENT version; `<SecretId>?versionStage=<label>` and
  `<SecretId>?versionId=<id>` pin one. A SecretId is a name, 1 to 512 of
  the characters CreateSecret allows (`A-Z a-z 0-9 / _ + = . @ -`), or a
  full secret ARN (`arn:<partition>:secretsmanager:<region>:<account>:secret:<name>-<suffix>`);
  a label is 1 to 256 of the name characters, a version id 32 to 64
  letters, digits and hyphens. Anything else is refused, so a value pasted
  into a handle field is refused rather than sent, and the refusal does not
  quote it.

The writer, `AwsSecretsManagerWriter`, is kci_aws_secret_writer's. That
package depends on this one for the grammar; this one does not depend on it
or on `kci_secret_writer`, so a target that only resolves has no write verb
in its closure.

The store takes the client by value, and the client carries everything that
decides where and as whom a call runs: the endpoint, the region, the
credential source and the HTTP time budget. The package reads no
environment. Every failure raises, naming the handle and carrying the
client's error (status, code, the service's `Message`; never a response
body); no error holds a value, and a handle the grammar refuses is not
quoted. The `Message` is carried on the assumption kci_aws_secret_writer's
README states: Secrets Manager does not repeat a value in it.

## Examples

Handles, and what the grammar refuses:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_raises, assert_true -->
```mojo
from komira_aws_secret_store import AWS_SELECTOR_VERSION_ID, AWS_SELECTOR_VERSION_STAGE, AWS_STAGE_CURRENT, AwsSecretRef, parse_aws_secret_ref

var current: AwsSecretRef = parse_aws_secret_ref("app/db")
assert_true(current.is_plain())  # resolves the version labelled AWS_STAGE_CURRENT
assert_equal(AWS_STAGE_CURRENT, "AWSCURRENT")

var pinned = parse_aws_secret_ref(String("app/db?") + AWS_SELECTOR_VERSION_ID + "=a1b2c3d4-5678-90ab-cdef-EXAMPLE11111")
assert_equal(pinned.version_id.value(), "a1b2c3d4-5678-90ab-cdef-EXAMPLE11111")
assert_equal(AWS_SELECTOR_VERSION_STAGE, "versionStage")

var previous = parse_aws_secret_ref("app/db?versionStage=AWSPREVIOUS")
assert_equal(previous.secret_id, "app/db")
assert_equal(previous.version_stage.value(), "AWSPREVIOUS")
assert_false(previous.is_plain())

with assert_raises(contains="neither versionId nor versionStage"):
    _ = parse_aws_secret_ref("app/db?label=AWSPREVIOUS")
with assert_raises(contains="is not a secret name"):
    _ = parse_aws_secret_ref('{"password":"hunter2"}')
with assert_raises(contains="not a full Secrets Manager secret ARN"):
    _ = parse_aws_secret_ref("arn:aws:secretsmanager:us-east-1:123456789012:secret:app/db")
```

A store. Its client answers from a scripted connector, one canned answer;
an application passes `KernelTcpConnector` behind TLS and its own
credential source, and the store owns its client:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_core import AwsCredential, StaticCredsSource
from komira_aws_secret_store import AwsSecretsManagerStore
from komira_aws_secretsmanager.komira_aws_secretsmanager import SecretsManagerClient, SecretsManagerEndpointConfig
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

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
```

## Tests

The welded test, `tests/test_aws_secret_store.mojo`, needs no socket: the
handle grammar and its refusals (a name's characters and length, a full
ARN's shape, the selectors' sets, a pasted value), none quoting the handle;
a resolve of a SecretString, of a SecretBinary and of an answer with neither
(raised); an error answer raised naming the handle, without the canary value
its body carried; and a handle outside the grammar refused before the
connector is dialled.

The service's behaviour is tested end to end in
`src/tests/e2e/komira_secrets_e2e` (`test_aws_store_registry`), against a
stateful fake of Secrets Manager on a real socket: values written through
kci_aws_secret_writer's writer and revealed through `SecretRegistry` into a
`CredentialConsumer`, by name, by staging label, by version id and by ARN,
and a missing secret raised. No test talks to AWS.
