# kci_aws_secret_writer

The write seam over AWS Secrets Manager, on the generated
`komira_aws_secretsmanager` client.

`AwsSecretsManagerWriter[C, T]` is a `kci_secret_writer.SecretWriter`.
`write` sends PutSecretValue (a new AWSCURRENT version) and, when the secret
does not exist, CreateSecret with the value; when that create finds the name
taken (another writer created it in between), PutSecretValue again.
`define_container` creates a secret with no version (an existing one is the
no-op). `has_version` reads DescribeSecret, metadata only, and answers
whether a version holds AWSCURRENT, the label a bare handle resolves to: a
secret whose only versions hold AWSPENDING or AWSPREVIOUS answers False. A
secret scheduled for deletion raises.

A writer's handle is the bare `<SecretId>` of komira_aws_secret_store's
grammar (`parse_aws_secret_ref`): a name, or a full ARN, which a write may
name but a create may not. The resolve seam, `AwsSecretsManagerStore`, is in
that package, and it does not depend on this one: a target that only
resolves has no writer in its closure.

The writer takes the client by value, and the client carries everything that
decides where and as whom a call runs: the endpoint, the region, the
credential source and the HTTP time budget. The package reads no
environment. A writer refuses a non-empty `deploy_token` before sending:
Secrets Manager signs with the client's credentials, so the deploy principal
is chosen by the credential source the client is built over. Every failure
raises, naming the handle and carrying the client's error: the status, the
code and the service's `Message`, never the response body. The `Message` is
carried as the service wrote it (control bytes as spaces, cut to a length
cap by komira_aws_core). That is safe on one assumption: Secrets Manager
does not repeat a request's SecretString in its `Message`, and its error
reference shows no message that does. The end-to-end test's worst-case fake
repeats the value in another member of its error bodies, and no raised text
holds it; a service that put the value into `Message` itself would defeat
this, and nothing here could tell. No error the writer raises otherwise
holds the value it was given.

## Examples

A writer and its probe. The clients here answer from scripted connectors,
one canned answer per client; an application passes `KernelTcpConnector`
behind TLS and its own credential source:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_raises, assert_true -->
```mojo
from komira_aws_core import AwsCredential, StaticCredsSource
from komira_aws_secret_store import AWS_STAGE_CURRENT
from komira_aws_secretsmanager.komira_aws_secretsmanager import SecretsManagerClient, SecretsManagerEndpointConfig
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_secret_store import SecretValue

from kci_aws_secret_writer import AwsSecretsManagerWriter

def _ok(body: String) raises -> ScriptedConnector:
    var http = (
        "HTTP/1.1 200 OK\r\nContent-Type: application/x-amz-json-1.1\r\n"
        + "Content-Length: " + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n" + body
    )
    var raw = List[UInt8]()
    raw.extend(Span(http.as_bytes()))
    return ScriptedConnector.with_stream(ScriptedStream.from_read_script(raw^))

def _put() raises -> ScriptedConnector:
    return _ok('{"Name":"app/db","VersionId":"a1b2c3d4-5678-90ab-cdef-EXAMPLE11111"}')

def _described() raises -> ScriptedConnector:
    return _ok('{"Name":"app/db","VersionIdsToStages":{"a1b2c3d4-5678-90ab-cdef-EXAMPLE11111":["AWSCURRENT"]}}')

def _pending() raises -> ScriptedConnector:
    return _ok('{"Name":"app/db","VersionIdsToStages":{"a1b2c3d4-5678-90ab-cdef-EXAMPLE11111":["AWSPENDING"]}}')

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

var writer = AwsSecretsManagerWriter(_client(_put))
writer.write("app/db", SecretValue.from_string("rotated"), "")
with assert_raises(contains="a deploy token was given"):
    writer.define_container("app/db", "a-bearer-token")

var probe = AwsSecretsManagerWriter(_client(_described))
assert_true(probe.has_version("app/db", ""))  # a version holds AWS_STAGE_CURRENT
assert_equal(AWS_STAGE_CURRENT, "AWSCURRENT")
var staged = AwsSecretsManagerWriter(_client(_pending))
assert_false(staged.has_version("app/db", ""))  # AWSPENDING only
```

## Tests

The welded test, `tests/test_aws_secret_writer.mojo`, needs no socket. It
covers every refusal (a deploy token, a handle with a selector, an ARN to
define, a handle outside the grammar, a value that is not UTF-8), each made
before the connector is dialled; the create-if-absent race (PutSecretValue
answered ResourceNotFoundException, CreateSecret answered
ResourceExistsException, PutSecretValue again, three sends) and a create
refused for another reason (raised, two sends); and the probe's reading of
DescribeSecret.

The service's behaviour is tested end to end in
`src/tests/e2e/komira_secrets_e2e` (`test_aws_store_registry`), against a
stateful fake of Secrets Manager on a real socket: create-if-absent, an
idempotent define, the probe on a missing, empty, written and
AWSPENDING-only secret, a secret scheduled for deletion, a wrongly keyed
probe raising, and the request log exactly. No test talks to AWS.
