# komira_aws_secretsmanager

An AWS Secrets Manager client for a secret's lifecycle, generated at build
time from botocore's pinned `secretsmanager` model (awsJson 1.1). The module
`komira_aws_secretsmanager.komira_aws_secretsmanager` holds, for
CreateSecret, PutSecretValue, GetSecretValue, DescribeSecret, DeleteSecret
and RestoreSecret:

- a request struct (`SecretsManager<Operation>Request`) and its builder
  `build_<operation>_request`, which returns a komira_aws_core `AwsRequest`
  (POST `/`, `X-Amz-Target: secretsmanager.<Operation>`, a JSON body),
  refusing a value outside the model's bounds before a request exists;
- a response parser `parse_<operation>_response` over a komira_aws_core
  `AwsResponse`, and the modeled error shapes, each read with
  `from_aws_json`;
- an endpoint resolver `resolve_<operation>_endpoint`, which runs the
  service's published endpoint ruleset
  (`komira_aws_secretsmanager_endpoint_rules()`) over a
  `SecretsManagerEndpointConfig`;
- `SecretsManagerClient`, which resolves each call's endpoint, signs it with
  SigV4 (signing name `secretsmanager`) and sends it over the
  komira_http_core `Connector` it is given, retried as botocore's standard
  mode retries. Its errors carry the HTTP status, the error code and the
  service's message, never the response body.

A write's `ClientRequestToken` is filled by the client verb with a fresh UUID
when unset, so every retry of the call carries the same token; the builders
send what they are given. DeleteSecret's verb is hand-written, in
`komira_aws_secretsmanager.secretsmanager_overrides`: `delete_secret`
refuses a recovery window together with a forced delete, and a window
outside 7..30 days, before anything is sent (`check_delete_secret_request`
is that check alone), and `secret_name_is_scheduled_for_deletion` recognises
a CreateSecret refused because the name is held by a secret scheduled for
deletion. Other Secrets Manager operations (rotation, listing) are not
generated. The package reads no environment.

## Examples

Build a CreateSecret request. Nothing is sent; the request is plain data:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_raises, assert_true -->
```mojo
from komira_aws_secretsmanager.komira_aws_secretsmanager import SecretsManagerCreateSecretRequest
from komira_aws_secretsmanager.komira_aws_secretsmanager import build_create_secret_request

var input = SecretsManagerCreateSecretRequest(String("app/db"))
input.set_client_request_token(String("EXAMPLE1-90ab-cdef-fedc-ba987SECRET1"))
input.set_secret_string(String('{"user":"app"}'))
var req = build_create_secret_request(input)
assert_equal(req.method, "POST")
assert_equal(req.uri, "/")
assert_equal(req.header(String("X-Amz-Target")), "secretsmanager.CreateSecret")
assert_equal(req.header(String("Content-Type")), "application/x-amz-json-1.1")
assert_equal(
    req.body_text(),
    '{"Name":"app/db","ClientRequestToken":"EXAMPLE1-90ab-cdef-fedc-ba987SECRET1",'
    + '"SecretString":"{\\"user\\":\\"app\\"}"}',
)
```

DeleteSecret's arguments, checked before anything is sent:

```mojo
from komira_aws_secretsmanager.komira_aws_secretsmanager import SecretsManagerDeleteSecretRequest
from komira_aws_secretsmanager.komira_aws_secretsmanager import build_delete_secret_request
from komira_aws_secretsmanager.secretsmanager_overrides import check_delete_secret_request
from komira_aws_secretsmanager.secretsmanager_overrides import secret_name_is_scheduled_for_deletion

var window = SecretsManagerDeleteSecretRequest(String("app/db"))
window.set_recovery_window_in_days(Int64(7))
check_delete_secret_request(window)
assert_equal(
    build_delete_secret_request(window).body_text(),
    '{"SecretId":"app/db","RecoveryWindowInDays":7}',
)

var too_short = SecretsManagerDeleteSecretRequest(String("app/db"))
too_short.set_recovery_window_in_days(Int64(3))
with assert_raises(contains="accepts 7..30"):
    check_delete_secret_request(too_short)

var both = SecretsManagerDeleteSecretRequest(String("app/db"))
both.set_recovery_window_in_days(Int64(7))
both.set_force_delete_without_recovery(True)
with assert_raises(contains="mutually exclusive"):
    check_delete_secret_request(both)

assert_true(
    secret_name_is_scheduled_for_deletion(
        String("InvalidRequestException: You can't create this secret because a secret")
        + " with this name is already scheduled for deletion."
    )
)
assert_false(secret_name_is_scheduled_for_deletion(String("ResourceExistsException")))
```

Decode a GetSecretValue answer, and read an error with komira_aws_core's
`aws_json_error_info` and the modeled error shape:

```mojo
from komira_aws_core import AwsResponse, aws_json_error_info
from komira_aws_secretsmanager.komira_aws_secretsmanager import SecretsManagerResourceNotFoundException
from komira_aws_secretsmanager.komira_aws_secretsmanager import parse_get_secret_value_response
from komira_json import parse_json_value

var out = parse_get_secret_value_response(
    AwsResponse.of_text(
        200,
        String(
            '{"Name":"app/db","SecretString":"s3cr3t","VersionStages":["AWSCURRENT"]}'
        ),
    )
)
assert_equal(out.name.value(), "app/db")
assert_equal(out.secret_string.value(), "s3cr3t")
assert_false(Bool(out.secret_binary))

var resp = AwsResponse.of_text(
    400,
    String(
        "{\"__type\":\"ResourceNotFoundException\","
        + "\"Message\":\"Secrets Manager can't find the specified secret.\"}"
    ),
)
var info = aws_json_error_info(resp)
assert_equal(info.code, "ResourceNotFoundException")
var err = SecretsManagerResourceNotFoundException.from_aws_json(parse_json_value(resp.body_text()))
assert_equal(err.message.value(), "Secrets Manager can't find the specified secret.")
```

Resolve the endpoint a call goes to:

```mojo
from komira_aws_secretsmanager.komira_aws_secretsmanager import SecretsManagerEndpointConfig
from komira_aws_secretsmanager.komira_aws_secretsmanager import SecretsManagerGetSecretValueRequest
from komira_aws_secretsmanager.komira_aws_secretsmanager import komira_aws_secretsmanager_endpoint_rules
from komira_aws_secretsmanager.komira_aws_secretsmanager import resolve_get_secret_value_endpoint

var resolved = resolve_get_secret_value_endpoint(
    komira_aws_secretsmanager_endpoint_rules(),
    SecretsManagerEndpointConfig(String("us-west-2")),
    SecretsManagerGetSecretValueRequest(String("app/db")),
)
assert_equal(resolved.url, "https://secretsmanager.us-west-2.amazonaws.com")
```
