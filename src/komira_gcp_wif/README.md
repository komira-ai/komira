# komira_gcp_wif

Google Cloud workload identity federation from AWS: an AWS workload proves
its AWS role to Google's Security Token Service and receives a federated
Google access token, with no Google key. Two legs:

1. `AwsWifTokenFetcher` is a komira_gcp_core `AccessTokenFetcher`. It signs
   AWS `GetCallerIdentity` with SigV4 (komira_aws_core's signer), serializes
   it as the `aws1` subject token Google's external-account credentials
   expect, and exchanges it at `sts.googleapis.com`. Wrapped in
   komira_gcp_core's `CachingTokenSource` it is a `GcpTokenSource`, the
   seam every generated Google client takes its bearer from.
2. `WifTokenMinter` takes any `GcpTokenSource` and calls IAM Credentials
   `signJwt` to mint a JWT self-signed by a service account. It is never
   dialed when the token source raises.

A third flow reads an `external_account` credentials file, the one a CI's
OIDC token is federated with. `parse_external_account` checks the file's
text (the caller reads the file; this package reads no environment), and
`ExternalAccountFetcher` takes the subject token from the file or URL the
file's `credential_source` names, exchanges it at the file's `token_url`
with the file's `audience` and `subject_token_type`, and, when the file
names a `service_account_impersonation_url`, trades the federated token for
the service account's through IAM Credentials `generateAccessToken`. An AWS
source, an `executable` source and a workforce pool's file are refused by
name.

Both legs send through komira_http_client over the komira_http_core
`Connector` the caller binds, and report a non-2xx answer through
komira_gcp_core's `parse_gcp_status`, which never echoes a body; a refused
token exchange names only an allow-listed OAuth error code. The pure parts
are public: `aws1_signed_request` / `aws1_subject_token`, `sts_exchange_form`
and `parse_sts_token_response`, `sign_jwt_path`, `sign_jwt_claims`,
`sign_jwt_request_body` and `parse_sign_jwt_response`.

The package reads no environment: the AWS credential comes from a
komira_aws_core `AwsCredsSource`, and the region, the provider audience and
the service account are arguments. It holds no other Google credential
flow (no service-account key, no metadata server).

## Examples

These examples run the pure parts with AWS's documentation key pair and a
fixed signing time; nothing is sent.

The subject token. The signed request is the empty-body `POST` AWS
verifies, signed over `host` and `x-amz-date` (and the session token, when
there is one); the provider's audience rides an unsigned header. The token
is the request as compact JSON, percent-encoded with `/` kept:

<!-- mojo-hidden from std.testing import assert_equal, assert_raises, assert_true -->
```mojo
from komira_aws_core import AwsCredential
from komira_gcp_wif import aws1_signed_request, aws_sts_host

comptime AUDIENCE = (
    "//iam.googleapis.com/projects/1234567890/locations/global/"
    + "workloadIdentityPools/example-pool/providers/example-aws"
    )

var credential = AwsCredential(
    String("AKIAIOSFODNN7EXAMPLE"),
    String("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
    String(""),  # no session token
)
var signed = aws1_signed_request(
    credential, String("us-east-1"), String(AUDIENCE), String("20261001T120000Z")
)
assert_equal(
    signed.url,
    "https://sts.us-east-1.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15",
)
assert_equal(signed.signed_headers, "host;x-amz-date")
assert_equal(signed.headers[0].name, "Authorization")
assert_true(signed.headers[0].value.startswith(
    "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-east-1/sts/aws4_request, "
))
assert_equal(signed.headers[3].name, "x-goog-cloud-target-resource")
assert_equal(signed.headers[3].value, AUDIENCE)

var token = signed.subject_token()
assert_true(token.startswith("%7B%22headers%22%3A%5B"))
assert_true("https%3A//sts.us-east-1.amazonaws.com%3F" in token)

# The region becomes a host Google calls, so only [a-z0-9-] passes.
assert_equal(aws_sts_host(String("eu-west-3")), "sts.eu-west-3.amazonaws.com")
with assert_raises(contains="outside [a-z0-9-]"):
    _ = aws_sts_host(String("evil.example/x"))
```

The token exchange, both ways: the form body sent to Google STS, and its
answer read into an access token expiring `expires_in` seconds after the
time it was received. A refusal names its OAuth error code only when the
code is a standard one, and never its description:

```mojo
from komira_gcp_wif import AWS_SUBJECT_TOKEN_TYPE, oauth_error_code, parse_sts_token_response, sts_exchange_form

var form = sts_exchange_form(
    String(AUDIENCE), String("scope-a"), String("tok"), String(AWS_SUBJECT_TOKEN_TYPE)
)
assert_true(form.startswith(
    "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Atoken-exchange&audience="
))
assert_true(form.endswith(
    "&subject_token=tok&subject_token_type=urn%3Aietf%3Aparams%3Aaws%3Atoken-type%3Aaws4_request"
))

var answer = List[UInt8]()
answer.extend(Span(String(
    '{"access_token":"ya29.example","issued_token_type":'
    + '"urn:ietf:params:oauth:token-type:access_token",'
    + '"token_type":"Bearer","expires_in":3599}'
).as_bytes()))
var access = parse_sts_token_response(answer, Int64(1_000_000))
assert_equal(access.token, "ya29.example")
assert_equal(access.expires_at_ms, Int64(1_000_000 + 3599 * 1000))

var refusal = List[UInt8]()
refusal.extend(Span(String(
    '{"error":"invalid_grant","error_description":"names the pool"}'
).as_bytes()))
assert_equal(oauth_error_code(refusal), "OAuth error invalid_grant")
```

The `signJwt` call: its path, the claims (`iss` and `sub` the account, a
10-minute lifetime), the body that carries them as a JSON string, and the
answer read:

```mojo
from komira_gcp_wif import parse_sign_jwt_response, sign_jwt_claims, sign_jwt_path, sign_jwt_request_body

comptime ACCOUNT = "minter@demo-project.example"
assert_equal(
    sign_jwt_path(String(ACCOUNT)),
    "/v1/projects/-/serviceAccounts/minter@demo-project.example:signJwt",
)
var claims = sign_jwt_claims(String(ACCOUNT), String("https://example.com"), 1790769600)
assert_equal(
    claims,
    String('{"iss":"') + ACCOUNT + '","sub":"' + ACCOUNT + '",'
    + '"aud":"https://example.com","iat":1790769600,"exp":1790770200}',
)
assert_true(sign_jwt_request_body(claims).startswith('{"payload":"{\\"iss\\":\\"minter@'))

var signed_answer = List[UInt8]()
signed_answer.extend(Span(String('{"keyId":"k1","signedJwt":"aaa.bbb.ccc"}').as_bytes()))
assert_equal(parse_sign_jwt_response(signed_answer), "aaa.bbb.ccc")
with assert_raises(contains="outside [A-Za-z0-9@._-]"):
    _ = sign_jwt_path(String("a/b"))
```

An `external_account` file read, and the impersonation request it leads to.
A missing field is refused by its name, never with a value from the file:

```mojo
from komira_gcp_wif import generate_access_token_body, parse_external_account

var config = parse_external_account(
    String('{"type":"external_account","audience":"') + AUDIENCE + '",'
    + '"subject_token_type":"urn:ietf:params:oauth:token-type:jwt",'
    + '"token_url":"https://sts.googleapis.com/v1/token",'
    + '"service_account_impersonation_url":"https://iamcredentials.googleapis.com'
    + '/v1/projects/-/serviceAccounts/deployer@demo-project.example:generateAccessToken",'
    + '"credential_source":{"file":"/var/run/ci/oidc-token"}}'
)
assert_equal(config.token_host, "sts.googleapis.com")
assert_true(config.impersonates())
assert_equal(config.source_file, "/var/run/ci/oidc-token")
assert_equal(
    generate_access_token_body(String("scope-a"), 3600),
    '{"scope":["scope-a"],"lifetime":"3600s"}',
)
with assert_raises(contains='has no "audience"'):
    _ = parse_external_account(String(
        '{"type":"external_account","subject_token_type":"t",'
        + '"token_url":"https://sts.googleapis.com/v1/token",'
        + '"credential_source":{"file":"/f"}}'
    ))
```
