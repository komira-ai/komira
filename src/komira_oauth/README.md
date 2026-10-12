# komira_oauth

OAuth 2.0 for a service that is a client of an issuer: it gets short-lived
access tokens for one audience from the issuer's token endpoint with the
`client_credentials` grant (RFC 6749 section 4.4), authenticating with a
signed assertion (`private_key_jwt`, RFC 7523 section 2.2) and naming the
audience as a `resource` (RFC 8707). Beside the client, the codecs of the
issuer's metadata (RFC 8414) and of a client's registration record (shaped
as RFC 7591 client metadata). Signing goes through `komira_jose`; keys come
from `komira_jwks`. The package holds no HTTP stack.

- `ClientCredentialSource[T](transport, signer, client_id=, token_endpoint=,
  assertion_audience=, resource=, scope=)` is one client asking for one
  resource. `access_token(now)` fetches on first use, serves the token it
  holds while `now < expires_at - 60` (`expires_at` is the request time plus
  the answer's `expires_in`), and fetches again from then on. The held token
  is dropped before every fetch: a fetch that fails raises, and the former
  token is never served after it, whether or not it has expired.
  `transport()` is the transport it owns.
- `fetch_client_credentials_token(transport, signer, ...)` is one request:
  it mints a client assertion (`iss = sub = client_id`, `aud` the issuer
  identifier or the token endpoint URL, 60 s, a random 128-bit `jti`), POSTs
  the form and reads a 200 answer. A transport failure, any other status
  (with the RFC 6749 error code when the body has a known one) and an answer
  it cannot read each raise a fixed `OAuthError: ...` text that holds no
  token, assertion or body byte.
- `TokenEndpointTransport` is the one method a transport has:
  `post_form(url, form) -> TokenEndpointReply{status, body}`, a POST with
  `Content-Type: application/x-www-form-urlencoded`.
- The token endpoint's wire: `ClientCredentialsRequest(...).form()` and
  `parse_client_credentials_request(body)`, which never raises and answers
  with the RFC 6749 error code a token endpoint returns
  (`ParsedTokenRequest.error`, `reason`, `request`); `render_token_response`
  and `parse_token_response` (`TokenResponse`); `render_oauth_error` and
  `oauth_error_code`, which repeats only a code from `oauth_error_codes()`.
  `FormParams`, `parse_form` and `form_encode_value` are the form encoding.
- RFC 8414: `authorization_server_metadata_url(issuer)`,
  `AuthorizationServerMetadata(...)` with `render()`, and
  `parse_authorization_server_metadata(doc, issuer)`, which requires the
  document's `issuer` to be the one it was fetched for, byte for byte.
- RFC 7591: `ClientMetadata.with_jwks(...)` or `.with_jwks_uri(...)`, with
  `render()`, and `parse_client_metadata(doc)`. The record holds
  `client_id`, `client_name`, `token_endpoint_auth_method` (always
  `private_key_jwt`), `token_endpoint_auth_signing_alg` (ES256 or EdDSA: the
  one algorithm the token endpoint verifies the client's assertions with),
  `grant_types` (always `["client_credentials"]`), `scope`, the client's
  public keys as `jwks` or `jwks_uri` (never both), and one extension member,
  `resource_types`. Members it does not know are ignored.

Every refusal raises `OAuthError: <fixed text>`. A service builds its
transport over its own HTTP client; tests use a scripted one.

## Example

An issuer's metadata, read from where RFC 8414 puts it:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_oauth import authorization_server_metadata_url, parse_authorization_server_metadata

var issuer = String("https://issuer.example/a")
assert_equal(
    authorization_server_metadata_url(issuer),
    "https://issuer.example/.well-known/oauth-authorization-server/a",
)
var doc = String('{"issuer":"https://issuer.example/a",') + (
    '"token_endpoint":"https://issuer.example/a/token",'
) + '"jwks_uri":"https://issuer.example/a/jwks"}'
var metadata = parse_authorization_server_metadata(doc, issuer)
assert_equal(metadata.token_endpoint, "https://issuer.example/a/token")
assert_equal(metadata.render(), doc)
```

A registration record and a token request, as a token endpoint reads them:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_oauth import ClientCredentialsRequest, ClientMetadata, parse_client_credentials_request
from komira_oauth import parse_client_metadata, parse_token_response, render_token_response

var types = List[String]()
types.append("doc")
var record = ClientMetadata.with_jwks_uri(
    client_id="service-b",
    client_name="",
    signing_alg="EdDSA",
    scope="read",
    jwks_uri="https://service-b.example/keys.json",
    resource_types=types,
)
var back = parse_client_metadata(record.render())
assert_equal(back.token_endpoint_auth_signing_alg, "EdDSA")
assert_equal(back.render(), record.render())

var form = ClientCredentialsRequest(
    client_assertion="aa.bb.cc", resource="https://pdp.example/v1", scope="read"
).form()
var parsed = parse_client_credentials_request(form)
assert_true(parsed.ok())
assert_equal(parsed.request.resource, "https://pdp.example/v1")
var refused = parse_client_credentials_request("grant_type=password")
assert_equal(refused.error, "unsupported_grant_type")

var answer = parse_token_response(render_token_response("t.o.k", 300, "read"))
assert_equal(answer.expires_in, 300)
```
